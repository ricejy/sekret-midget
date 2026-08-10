# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI with
`--repo ricejy/sekret-midget` for all operations.

## Conventions

- Create: `gh issue create --repo ricejy/sekret-midget --title "..." --body-file <file>`
- Read: `gh issue view <number> --repo ricejy/sekret-midget --comments`
- List: `gh issue list --repo ricejy/sekret-midget --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --repo ricejy/sekret-midget --body-file <file>`
- Add or remove labels with `gh issue edit`
- Close with `gh issue close`

Use temporary files and `--body-file` for multiline bodies in PowerShell.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares one number space across issues and pull requests. Resolve an
ambiguous reference with `gh pr view`, falling back to `gh issue view`.

## Skill terminology

- “Publish to the issue tracker” means creating a GitHub issue.
- “Fetch the relevant ticket” means reading the GitHub issue and its comments.

## Wayfinding operations

The map is a GitHub issue labelled `wayfinder:map`. Child tickets are linked
as GitHub sub-issues where available, with task-list links as a fallback.

Use `wayfinder:<type>` labels for child tickets, where the type is `research`,
`prototype`, `grilling`, or `task`.

Represent blocking relationships with GitHub’s native issue dependencies.
Where unavailable, add `Blocked by: #<number>` to the child issue.

An unblocked, unassigned child is available work. Claim it by assigning the
current GitHub user. Resolve it by posting the answer, closing it, and adding
the resulting context pointer to the map.
