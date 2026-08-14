abstract interface class OcrEngine {
  Future<String> recognizeText(List<int> imageBytes);
}
