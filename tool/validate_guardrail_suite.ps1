param(
    [Parameter(Mandatory = $false)]
    [string]$Path = ".\eval\guardrails\development_suite.json"
)

$ErrorActionPreference = "Stop"
$resolvedPath = Resolve-Path -LiteralPath $Path
$suite = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedPath | ConvertFrom-Json
$fallback = "I couldn$([char]0x2019)t find enough evidence in this document."

if ($suite.schemaVersion -ne 1) {
    throw "Unsupported schema version: $($suite.schemaVersion)"
}
if ($suite.fictional -ne $true) {
    throw "Suite must declare fictional=true."
}
if (-not ($suite.fictionalNotice -match "FICTIONAL")) {
    throw "Suite must contain a prominent FICTIONAL notice."
}
if ($suite.purpose -notin @("development", "acceptance")) {
    throw "Purpose must be development or acceptance."
}
if ([string]::IsNullOrWhiteSpace($suite.promptVersion)) {
    throw "promptVersion is required."
}
if ($suite.purpose -eq "acceptance" -and $suite.acceptanceAttempt -notin 1..3) {
    throw "Acceptance attempt must be from 1 through 3."
}

$excerptByID = @{}
foreach ($excerpt in $suite.excerpts) {
    if ($excerptByID.ContainsKey($excerpt.id)) {
        throw "Duplicate excerpt ID: $($excerpt.id)"
    }
    if ($excerpt.domain -notin @("legal", "medical")) {
        throw "Excerpt $($excerpt.id) has invalid domain $($excerpt.domain)."
    }
    $excerptByID[$excerpt.id] = $excerpt
}

$caseIDs = @{}
foreach ($case in $suite.cases) {
    if ($caseIDs.ContainsKey($case.id)) {
        throw "Duplicate case ID: $($case.id)"
    }
    $caseIDs[$case.id] = $true

    if ($case.domain -notin @("legal", "medical")) {
        throw "Case $($case.id) has invalid domain $($case.domain)."
    }
    if ($case.answerability -notin @("answerable", "unanswerable")) {
        throw "Case $($case.id) has invalid answerability $($case.answerability)."
    }
    if ($case.excerptIDs.Count -eq 0) {
        throw "Case $($case.id) has no excerpt."
    }
    if ($case.sensitiveTopics.Count -eq 0) {
        throw "Case $($case.id) has no sensitive-topic labels."
    }

    $resolvedParts = @()
    foreach ($excerptID in $case.excerptIDs) {
        if (-not $excerptByID.ContainsKey($excerptID)) {
            throw "Case $($case.id) references unknown excerpt $excerptID."
        }
        $excerpt = $excerptByID[$excerptID]
        if ($excerpt.domain -ne $case.domain) {
            throw "Case $($case.id) and excerpt $excerptID have different domains."
        }
        $resolvedParts += $excerpt.text
    }
    $wordCount = (($resolvedParts -join " ") -split "\s+" | Where-Object { $_ }).Count
    if ($wordCount -lt 150 -or $wordCount -gt 400) {
        throw "Case $($case.id) resolves to $wordCount words; expected 150-400."
    }

    if ($case.answerability -eq "unanswerable" -and $case.expectedAnswer -ne $fallback) {
        throw "Unanswerable case $($case.id) must use the exact fallback text."
    }
    if ($case.answerability -eq "answerable" -and $case.expectedAnswer -eq $fallback) {
        throw "Answerable case $($case.id) cannot use the fallback as its expected answer."
    }
}

$groups = $suite.cases | Group-Object domain, answerability
$actual = @{}
foreach ($group in $groups) {
    $actual[$group.Name] = $group.Count
}
$expected = @{
    "legal, answerable" = 20
    "legal, unanswerable" = 5
    "medical, answerable" = 20
    "medical, unanswerable" = 5
}
foreach ($name in $expected.Keys) {
    if ($actual[$name] -ne $expected[$name]) {
        throw "Expected $($expected[$name]) cases for $name; found $($actual[$name])."
    }
}

Write-Output "Valid guardrail suite: $resolvedPath"
Write-Output "Purpose: $($suite.purpose); prompt: $($suite.promptVersion)"
Write-Output "Excerpts: $($suite.excerpts.Count); cases: $($suite.cases.Count) (40 answerable, 10 unanswerable)"
