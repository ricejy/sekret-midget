import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_workspace.dart';
import '../core/knowledge/knowledge_base.dart';
import '../core/platform/apple_embedder.dart';
import '../core/platform/apple_foundation_models.dart';
import '../core/platform/apple_vision_ocr.dart';
import '../core/platform/device_protection.dart';
import '../core/platform/pdfrx_pdf_page_rasterizer.dart';
import '../core/platform/pdfrx_pdf_text_extractor.dart';
import '../core/storage/local_data_vault.dart';
import '../ui/sekret_chat_app.dart';

/// Separate executable, never reachable from the normal app's main().
/// Keeps actual device authentication while isolating every test vault record.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Banner(
        message: 'TEST DATA',
        location: BannerLocation.topEnd,
        child: SekretChatApp(openResources: _openAcceptance),
      ),
    ),
  );
}

Future<ChatAppResources> _openAcceptance() async {
  if (!Platform.isIOS) throw StateError('The manual gate requires iPhone.');
  final support = await getApplicationSupportDirectory();
  final directory = await Directory(
    '${support.path}/settings-acceptance',
  ).create(recursive: true);
  final path = '${directory.path}/sekret-settings-acceptance.sqlite3';
  final models = AppleFoundationModels();
  await models.protectStorage(
    directoryPath: directory.path,
    databasePath: path,
  );
  final vault = await openLocalDataVault(databasePath: path);
  ChatWorkspace? workspace;
  KnowledgeBase? knowledge;
  ChatAppResources? resources;
  try {
    await models.protectStorage(
      directoryPath: directory.path,
      databasePath: path,
    );
    workspace = await ChatWorkspace.open(vault);
    knowledge = await KnowledgeBase.open(
      vault: vault,
      embedder: AppleEmbedder(),
      tokenCounter: models,
      pdfLoader: const PdfrxDocumentLoader(),
      rasterizer: const PdfrxPdfPageRasterizer(),
      ocr: AppleVisionOcr(),
    );
    final engine = ChatEngine(
      workspace: workspace,
      backend: models,
      contextProbe: models,
      groundedBackend: models,
      knowledgeBase: knowledge,
      model: ModelSnapshot(
        identifier: 'apple-foundation-models',
        revision: Platform.operatingSystemVersion,
      ),
    );
    resources = ChatAppResources(
      vault,
      workspace,
      knowledge,
      engine,
      models,
      device: const _AcceptanceProtection(),
    );
    // Seed once before onboarding. Erase All preserves onboarding completion,
    // so erased fixtures do not reappear after a cold launch.
    if (!(await vault.settings.get()).onboardingComplete &&
        (await vault.chats.listChats()).isEmpty &&
        (await vault.knowledge.list()).isEmpty) {
      await knowledge.importText(
        title: 'Fictional acceptance source',
        text:
            'This is fictional test data. The sample project is Bluebird. Its review day is Friday.',
      );
      final chat = await workspace.newChat();
      await workspace.rename(chat.id, 'Fictional acceptance chat');
      await vault.chats.appendTurn(
        chatId: chat.id,
        userText: 'What is this test?',
        assistantText:
            'This is a fictional acceptance chat. Your regular vault is not used.',
        outcome: TurnOutcome.completed,
        mode: ChatMode.general,
        sourceScopeIds: const [],
        evidencePassageIds: const [],
        citationEvidenceIndexes: const [],
        model: const ModelSnapshot(
          identifier: 'seeded-test-fixture',
          revision: '1',
        ),
      );
    }
    return resources;
  } on Object {
    if (resources != null) {
      await resources.close();
    } else {
      await knowledge?.dispose();
      await workspace?.dispose();
      await vault.close();
    }
    rethrow;
  }
}

final class _AcceptanceProtection implements DeviceProtection {
  const _AcceptanceProtection();
  static const _native = AppleDeviceProtection();
  @override
  Future<bool> authenticate() => _native.authenticate();
  @override
  Future<Map<String, String>> diagnostics() => _native.diagnostics();
  // Older production picker copies share this app sandbox. The manual gate
  // must not purge them. Native purge/path confinement is verified separately.
  @override
  Future<void> purgeImportCopies() async {}
}
