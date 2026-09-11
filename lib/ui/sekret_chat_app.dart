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
import '../core/platform/device_protection.dart';
import '../core/settings/app_protection.dart';
import '../core/platform/pdfrx_pdf_page_rasterizer.dart';
import '../core/platform/pdfrx_pdf_text_extractor.dart';
import '../core/storage/local_data_vault.dart';
import 'chat/chat_screen.dart';
import 'knowledge/source_preview.dart';
import 'knowledge/knowledge_screen.dart';
import 'settings/settings_screen.dart';
import 'settings/onboarding_screen.dart';

class ChatAppResources {
  ChatAppResources(
    this.vault,
    this.workspace,
    this.knowledge,
    this.engine,
    this.models, {
    DeviceProtection device = const AppleDeviceProtection(),
  }) : protection = AppProtection(vault.settings, device);
  final AppProtection protection;
  final LocalDataVault vault;
  final ChatWorkspace workspace;
  final KnowledgeBase knowledge;
  final ChatEngine engine;
  final AppleFoundationModels models;
  Future<void> close() async {
    protection.dispose();
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
  final _rootNavigator = GlobalKey<NavigatorState>();
  bool _wasLocked = true;
  bool _obscured = false;
  bool _maintenance = false;
  String? _operationError;
  Future<void> _lifecycle = Future.value();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _obscured =
        WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    _resourcesFuture = Future.sync(widget.openResources).then((
      resources,
    ) async {
      try {
        await resources.protection.initialize();
        return resources;
      } on Object {
        await resources.close();
        rethrow;
      }
    });
    _resourcesFuture.then((resources) async {
      if (!mounted) {
        await resources.close();
        return;
      }
      _resources = resources;
      setState(() {});
      _wasLocked = resources.protection.locked;
      resources.protection.addListener(_protectionChanged);
      if (_obscured) resources.protection.inactive();
      if (!_obscured && !resources.protection.locked) {
        unawaited(resources.knowledge.resume().catchError((Object _) {}));
      }
    }, onError: (Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _obscured = state != AppLifecycleState.resumed);
    final resources = _resources;
    if (resources == null) return;
    if (state == AppLifecycleState.inactive) resources.protection.inactive();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      resources.protection.background();
    }
    if (state == AppLifecycleState.resumed) resources.protection.resumed();
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
            if (!mounted ||
                _obscured ||
                _maintenance ||
                resources.protection.locked) {
              return;
            }
            await resources.engine.resume();
            if (!mounted ||
                _obscured ||
                _maintenance ||
                resources.protection.locked) {
              return;
            }
            unawaited(resources.knowledge.resume().catchError((Object _) {}));
          }
        })
        .catchError((Object _) {
          /* Persisted recovery runs on the next resume. */
        });
  }

  void _protectionChanged() {
    final locked = _resources?.protection.locked ?? true;
    if (locked && !_wasLocked) {
      _rootNavigator.currentState?.popUntil((route) => route.isFirst);
      final resources = _resources!;
      _lifecycle = Future.wait([
        _lifecycle,
        resources.engine.suspend(),
        resources.knowledge.suspend(),
      ]).then<void>((_) {}).catchError((Object _) {});
    }
    _wasLocked = locked;
    if (mounted) setState(() {});
  }

  Future<void> _unlock(ChatAppResources resources) async {
    await resources.protection.unlock();
    if (!mounted || _obscured || _maintenance || resources.protection.locked) {
      return;
    }
    _lifecycle = _lifecycle
        .then((_) async {
          if (!mounted ||
              _obscured ||
              _maintenance ||
              resources.protection.locked) {
            return;
          }
          await resources.engine.resume();
          unawaited(resources.knowledge.resume().catchError((Object _) {}));
        })
        .catchError((Object _) {});
  }

  Future<void> _deleteData(LocalDataAction action) async {
    final resources = _resources!;
    if (_maintenance || resources.protection.locked || _obscured) return;
    // Always authenticate Erase All, even when optional app lock is off.
    if (action == LocalDataAction.everything &&
        !await resources.protection.authenticate()) {
      throw StateError('Authentication required.');
    }
    if (!mounted || _obscured || resources.protection.locked) return;
    setState(() {
      _maintenance = true;
      _operationError = null;
    });
    // Unmount all tab navigators, previews, editors, drafts, and Undo surfaces
    // before touching data. Admission stops now, not after queued lifecycle work.
    final knowledgeStopped = resources.knowledge.suspend();
    final engineStopped = resources.engine.suspend();
    try {
      await WidgetsBinding.instance.endOfFrame;
      await _lifecycle;
      await engineStopped;
      await knowledgeStopped;
      switch (action) {
        case LocalDataAction.chats:
          await resources.workspace.deleteAllChats();
        case LocalDataAction.knowledge:
          for (final item in await resources.vault.knowledge.list()) {
            await resources.knowledge.delete(item.id);
          }
          await resources.protection.device.purgeImportCopies();
        case LocalDataAction.everything:
          await resources.workspace.deleteAllChats();
          await resources.vault.eraseAll();
          await resources.protection.device.purgeImportCopies();
      }
      await resources.workspace.resume();
    } on Object {
      _operationError =
          'Deletion could not be fully completed. Check storage and retry.';
    } finally {
      if (mounted) {
        _tabs.index = 2;
        setState(() => _maintenance = false);
        if (!_obscured && !resources.protection.locked) {
          await resources.engine.resume();
          unawaited(resources.knowledge.resume().catchError((Object _) {}));
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    final resources = _resources;
    if (resources != null) {
      resources.protection.removeListener(_protectionChanged);
      unawaited(_lifecycle.whenComplete(resources.close));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoApp(
    navigatorKey: _rootNavigator,
    localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
    title: 'Sekret',
    debugShowCheckedModeBanner: false,
    theme: const CupertinoThemeData(
      primaryColor: CupertinoColors.systemBlue,
      scaffoldBackgroundColor: CupertinoColors.systemBackground,
    ),
    // Wrap the navigator, not only the home: modal dialogs and sheets must
    // disappear from snapshots and accessibility too.
    builder: (context, child) => Stack(
      children: [
        ExcludeSemantics(
          excluding: _obscured || (_resources?.protection.locked ?? false),
          child: IgnorePointer(
            ignoring: _obscured || (_resources?.protection.locked ?? false),
            child: child,
          ),
        ),
        if (!_obscured && (_resources?.protection.locked ?? false))
          Positioned.fill(child: _lockScreen(_resources!)),
        if (_obscured)
          Positioned.fill(
            child: ColoredBox(
              color: CupertinoColors.systemBackground.resolveFrom(context),
              child: const Center(child: Text('Sekret')),
            ),
          ),
      ],
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
        if (_maintenance) {
          return const CupertinoPageScaffold(
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        if (resources.protection.locked) {
          return const SizedBox.shrink();
        }
        if (!resources.protection.settings!.onboardingComplete) {
          return OnboardingScreen(
            protection: resources.protection,
            model: resources.models,
            openSystemSettings: resources.models.openSettings,
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
                          builder: (_) => SourcePreview(
                            knowledge: resources.knowledge,
                            location: preview.location,
                          ),
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
                  if (index == 1) {
                    return KnowledgeScreen(knowledge: resources.knowledge);
                  }
                  return SettingsScreen(
                    vault: resources.vault,
                    workspace: resources.workspace,
                    protection: resources.protection,
                    model: resources.models,
                    openSystemSettings: resources.models.openSettings,
                    deleteData: _deleteData,
                  );
                },
              ),
            ),
            if (_operationError != null)
              Positioned(
                left: 16,
                right: 16,
                top: 70,
                child: CupertinoButton(
                  color: CupertinoColors.systemGrey5,
                  onPressed: () => setState(() => _operationError = null),
                  child: Text(_operationError!),
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _lockScreen(ChatAppResources resources) => CupertinoPageScaffold(
    child: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.lock_shield, size: 48),
              const SizedBox(height: 16),
              const Text('Sekret is locked'),
              if (resources.protection.error != null)
                Text(resources.protection.error!),
              CupertinoButton(
                onPressed: resources.protection.authenticating
                    ? null
                    : () => _unlock(resources),
                child: const Text('Unlock Sekret'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
