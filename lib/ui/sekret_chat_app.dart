import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_workspace.dart';
import '../core/knowledge/knowledge_base.dart';
import '../core/platform/apple_embedder.dart';
import '../core/platform/apple_foundation_models.dart';
import '../core/platform/apple_vision_ocr.dart';
import '../core/platform/pdfrx_pdf_page_rasterizer.dart';
import '../core/platform/pdfrx_pdf_text_extractor.dart';
import '../core/storage/local_data_vault.dart';
import 'chat/chat_screen.dart';
import 'chat/source_preview.dart';

class ChatAppResources {
  ChatAppResources(
    this.vault,
    this.workspace,
    this.knowledge,
    this.engine,
    this.models,
  );
  final LocalDataVault vault;
  final ChatWorkspace workspace;
  final KnowledgeBase knowledge;
  final ChatEngine engine;
  final AppleFoundationModels models;
  Future<void> close() async {
    await engine.dispose();
    await knowledge.dispose();
    await workspace.dispose();
    await vault.close();
  }
}

Future<ChatAppResources> openChatApp() async {
  if (!Platform.isIOS) {
    throw StateError('The production v2 app requires iPhone.');
  }
  final directory = await getApplicationSupportDirectory();
  final path =
      '${directory.path}${Platform.pathSeparator}sekret-midget.sqlite3';
  final models = AppleFoundationModels();
  await models.protectStorage(
    directoryPath: directory.path,
    databasePath: path,
  );
  // Never reset an old/unknown database here. Transition needs fresh confirmation.
  final vault = await openLocalDataVault(databasePath: path);
  ChatWorkspace? workspace;
  KnowledgeBase? knowledge;
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
    return ChatAppResources(vault, workspace, knowledge, engine, models);
  } on Object {
    await knowledge?.dispose();
    await workspace?.dispose();
    await vault.close();
    rethrow;
  }
}

/// Opt-in while the remaining v2 tabs are implemented. No silent v1 reset.
class SekretChatApp extends StatefulWidget {
  const SekretChatApp({super.key, required this.openResources});
  final Future<ChatAppResources> Function() openResources;
  @override
  State<SekretChatApp> createState() => _SekretChatAppState();
}

class _SekretChatAppState extends State<SekretChatApp>
    with WidgetsBindingObserver {
  ChatAppResources? _resources;
  late final Future<ChatAppResources> _resourcesFuture;
  final _tabs = CupertinoTabController();
  bool _obscured = false;
  Future<void> _lifecycle = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resourcesFuture = Future.sync(widget.openResources);
    _resourcesFuture.then((resources) async {
      if (!mounted) {
        await resources.close();
        return;
      }
      _resources = resources;
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(resources.knowledge.resume().catchError((Object _) {}));
      }
    }, onError: (Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _obscured = state != AppLifecycleState.resumed);
    final resources = _resources;
    if (resources == null) return;
    // Pause admission immediately, even if a foreground resume is indexing.
    // Never queue suspension behind a complete import batch.
    final pausingKnowledge =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden
        ? resources.knowledge.suspend()
        : null;
    _lifecycle = _lifecycle
        .then((_) async {
          if (state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden) {
            await resources.engine.suspend();
            await pausingKnowledge;
          } else if (state == AppLifecycleState.resumed) {
            if (!mounted || _obscured) return;
            await resources.engine.resume();
            if (!mounted || _obscured) return;
            unawaited(resources.knowledge.resume().catchError((Object _) {}));
          }
        })
        .catchError((Object _) {
          /* Persisted recovery runs on the next resume. */
        });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    final resources = _resources;
    if (resources != null) unawaited(_lifecycle.whenComplete(resources.close));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
    localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
    title: 'Sekret',
    debugShowCheckedModeBanner: false,
    theme: const CupertinoThemeData(
      primaryColor: CupertinoColors.systemBlue,
      scaffoldBackgroundColor: CupertinoColors.systemBackground,
    ),
    home: FutureBuilder<ChatAppResources>(
      future: _resourcesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const CupertinoPageScaffold(
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'The v2 workspace could not be opened. Existing data has not been reset. The v1-to-v2 transition needs explicit confirmation; turn off SEKRET_V2 to return to the current build.',
                  ),
                ),
              ),
            ),
          );
        }
        final resources = snapshot.data;
        if (resources == null) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        return Stack(
          children: [
            CupertinoTabScaffold(
              controller: _tabs,
              tabBar: CupertinoTabBar(
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.chat_bubble_2),
                    label: 'Chat',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.folder),
                    label: 'Knowledge Base',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.settings),
                    label: 'Settings',
                  ),
                ],
              ),
              tabBuilder: (_, index) => CupertinoTabView(
                builder: (context) {
                  if (index == 0) {
                    return ChatScreen(
                      workspace: resources.workspace,
                      engine: resources.engine,
                      knowledge: resources.knowledge,
                      onKnowledgeBase: () => _tabs.index = 1,
                      onPreview: (preview) => Navigator.of(context).push<void>(
                        CupertinoPageRoute(
                          builder: (_) => SourcePreview(preview: preview),
                        ),
                      ),
                      onLink: (uri) async {
                        if (!await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw StateError('Link unavailable');
                        }
                      },
                      onSettings: resources.models.openSettings,
                    );
                  }
                  return CupertinoPageScaffold(
                    navigationBar: CupertinoNavigationBar(
                      middle: Text(index == 1 ? 'Knowledge Base' : 'Settings'),
                    ),
                    child: SafeArea(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            index == 1
                                ? 'The catalogue and import interface is the next refinement ticket. Your existing v2 sources remain available in Chat.'
                                : 'Settings and app protection are coming in the following refinement ticket.',
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_obscured)
              const Positioned.fill(
                child: ColoredBox(
                  color: CupertinoColors.systemGrey6,
                  child: Center(child: Text('Sekret')),
                ),
              ),
          ],
        );
      },
    ),
  );
}
