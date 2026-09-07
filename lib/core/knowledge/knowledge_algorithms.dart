import 'dart:math' as math;
import 'dart:typed_data';

import '../platform/token_counter.dart';

// Shared v1/v2 ingestion and retrieval primitives. Keep baseline behavior stable.
List<int> fuseRanks(List<int> lexical, List<int> dense) {
  final rankConstant = productionRetrievalConfiguration.reciprocalRankConstant;
  final scores = <int, double>{};
  for (var index = 0; index < lexical.length; index += 1) {
    scores.update(
      lexical[index],
      (score) => score + 1 / (rankConstant + index + 1),
      ifAbsent: () => 1 / (rankConstant + index + 1),
    );
  }
  for (var index = 0; index < dense.length; index += 1) {
    scores.update(
      dense[index],
      (score) => score + 1 / (rankConstant + index + 1),
      ifAbsent: () => 1 / (rankConstant + index + 1),
    );
  }
  final ranked = scores.entries.toList()
    ..sort((left, right) => right.value.compareTo(left.value));
  return [
    for (final entry in ranked.take(
      productionRetrievalConfiguration.candidateLimit,
    ))
      entry.key,
  ];
}

enum RetrievalMode { hybrid, denseOnly }

final class RetrievalConfiguration {
  const RetrievalConfiguration({
    required this.targetChunkTokens,
    required this.overlapTokens,
    required this.candidateLimit,
    required this.reciprocalRankConstant,
    required this.contextPassageLimit,
    required this.maximumContextTokens,
    required this.answerTokenReservation,
  });

  final int targetChunkTokens;
  final int overlapTokens;
  final int candidateLimit;
  final int reciprocalRankConstant;
  final int contextPassageLimit;
  final int maximumContextTokens;
  final int answerTokenReservation;
}

const productionRetrievalConfiguration = RetrievalConfiguration(
  targetChunkTokens: 250,
  overlapTokens: 38,
  candidateLimit: 20,
  reciprocalRankConstant: 60,
  contextPassageLimit: 4,
  maximumContextTokens: 4096,
  answerTokenReservation: 512,
);

final class SourcePage {
  const SourcePage({required this.text, required this.page});

  final String text;
  final int? page;
}

final class TextChunk {
  const TextChunk({
    required this.text,
    required this.heading,
    required this.page,
  });

  final String text;
  final String heading;
  final int? page;
}

final class QuantizedVector {
  const QuantizedVector(this.bytes, this.scale);

  final Uint8List bytes;
  final double scale;
}

Future<List<TextChunk>> chunkSourcePages(
  List<SourcePage> pages,
  TokenCounter tokenCounter,
) async {
  final targetTokens = productionRetrievalConfiguration.targetChunkTokens;
  final overlapTokens = productionRetrievalConfiguration.overlapTokens;
  final chunks = <TextChunk>[];
  for (final sourcePage in pages) {
    final sections = _parseSections(sourcePage.text);
    for (final section in sections) {
      final sentences = <_SentenceUnit>[];
      for (final paragraph in section.paragraphs) {
        final paragraphSentences = paragraph
            .split(RegExp(r'(?<=[.!?;])\s+'))
            .where((sentence) => sentence.trim().isNotEmpty)
            .toList();
        for (var index = 0; index < paragraphSentences.length; index += 1) {
          sentences.add(
            _SentenceUnit(
              text: paragraphSentences[index].trim(),
              startsParagraph: index == 0,
            ),
          );
        }
      }
      final current = <_SentenceUnit>[];
      var currentTokens = 0;
      for (final sentence in sentences) {
        final sentenceTokens = await tokenCounter.countTokens(sentence.text);
        if (current.isNotEmpty &&
            currentTokens + sentenceTokens > targetTokens) {
          chunks.add(
            TextChunk(
              text: _joinSentences(current),
              heading: section.heading,
              page: sourcePage.page,
            ),
          );
          final overlap = <_SentenceUnit>[];
          var overlapCount = 0;
          for (final prior in current.reversed) {
            final priorTokens = await tokenCounter.countTokens(prior.text);
            if (overlapCount + priorTokens > overlapTokens) {
              if (overlap.isEmpty) {
                overlap.insert(0, prior);
                overlapCount += priorTokens;
              }
              break;
            }
            overlap.insert(0, prior);
            overlapCount += priorTokens;
          }
          current
            ..clear()
            ..addAll(overlap);
          currentTokens = overlapCount;
        }
        current.add(sentence);
        currentTokens += sentenceTokens;
      }
      if (current.isNotEmpty) {
        chunks.add(
          TextChunk(
            text: _joinSentences(current),
            heading: section.heading,
            page: sourcePage.page,
          ),
        );
      }
    }
  }
  return chunks;
}

final class _SentenceUnit {
  const _SentenceUnit({required this.text, required this.startsParagraph});

  final String text;
  final bool startsParagraph;
}

String _joinSentences(List<_SentenceUnit> sentences) {
  final buffer = StringBuffer();
  for (var index = 0; index < sentences.length; index += 1) {
    final sentence = sentences[index];
    if (index > 0) {
      buffer.write(sentence.startsParagraph ? '\n\n' : ' ');
    }
    buffer.write(sentence.text);
  }
  return buffer.toString();
}

final class _Section {
  const _Section({required this.heading, required this.paragraphs});

  final String heading;
  final List<String> paragraphs;
}

List<_Section> _parseSections(String text) {
  final sections = <_Section>[];
  var heading = '';
  final paragraphs = <String>[];
  final paragraphLines = <String>[];

  void flushParagraph() {
    final paragraph = paragraphLines.join(' ').trim();
    if (paragraph.isNotEmpty) {
      paragraphs.add(paragraph);
      paragraphLines.clear();
    }
  }

  void flushSection() {
    flushParagraph();
    if (paragraphs.isNotEmpty) {
      sections.add(_Section(heading: heading, paragraphs: List.of(paragraphs)));
      paragraphs.clear();
    }
  }

  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) {
      flushParagraph();
      continue;
    }
    if (_looksLikeHeading(line)) {
      flushSection();
      heading = line;
    } else {
      paragraphLines.add(line);
    }
  }
  flushSection();
  return sections;
}

bool _looksLikeHeading(String line) {
  if (line.length > 100 || line.endsWith('.') || line.endsWith(';')) {
    return false;
  }
  final letters = line.replaceAll(RegExp('[^A-Za-z]'), '');
  if (letters.length < 3) {
    return false;
  }
  if (letters == letters.toUpperCase()) {
    return true;
  }
  const connectors = {'a', 'an', 'and', 'for', 'of', 'or', 'the', 'to'};
  final words = RegExp(
    '[A-Za-z]+',
  ).allMatches(line).map((match) => match.group(0)!).toList();
  return words.isNotEmpty &&
      words.every(
        (word) =>
            connectors.contains(word) ||
            word.codeUnitAt(0) >= 65 && word.codeUnitAt(0) <= 90,
      );
}

String ftsQuery(String question) {
  const stopWords = {
    'a',
    'an',
    'and',
    'are',
    'does',
    'how',
    'is',
    'must',
    'the',
    'to',
    'what',
    'when',
    'within',
  };
  final terms = question
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty && !stopWords.contains(term))
      .toSet();
  return terms.map((term) => '"${term.replaceAll('"', '""')}"').join(' OR ');
}

QuantizedVector quantize(List<double> vector) {
  if (vector.isEmpty) {
    return QuantizedVector(Uint8List(0), 1);
  }
  final maximum = vector.fold<double>(
    0,
    (current, value) => math.max(current, value.abs()),
  );
  if (maximum == 0) {
    return QuantizedVector(Uint8List(vector.length), 1);
  }
  final scale = maximum / 127;
  final bytes = Uint8List(vector.length);
  for (var index = 0; index < vector.length; index += 1) {
    final quantized = (vector[index] / scale).round().clamp(-127, 127);
    bytes[index] = quantized < 0 ? quantized + 256 : quantized;
  }
  return QuantizedVector(bytes, scale);
}

List<double> dequantize(Uint8List bytes, double scale) {
  return [for (final byte in bytes) (byte > 127 ? byte - 256 : byte) * scale];
}

double cosineSimilarity(List<double> left, List<double> right) {
  if (left.length != right.length || left.isEmpty) {
    return 0;
  }
  var dotProduct = 0.0;
  var leftMagnitude = 0.0;
  var rightMagnitude = 0.0;
  for (var index = 0; index < left.length; index += 1) {
    dotProduct += left[index] * right[index];
    leftMagnitude += left[index] * left[index];
    rightMagnitude += right[index] * right[index];
  }
  if (leftMagnitude == 0 || rightMagnitude == 0) {
    return 0;
  }
  return dotProduct / math.sqrt(leftMagnitude * rightMagnitude);
}
