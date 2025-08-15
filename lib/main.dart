// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:makarna_app/screens/splash_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'firebase_options.dart';

// Zaman dilimi için importlar
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_timezone/flutter_timezone.dart';

// Ortam Değişkenleri ve Servisler
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'services/connectivity_service.dart';
import 'services/cache_service.dart';
import 'services/sync_service.dart';
import 'services/global_notification_handler.dart' as globalHandler;
import 'services/connection_manager.dart';
import 'services/socket_service.dart';
import 'services/user_session.dart';
import 'models/sync_queue_item.dart';
import 'models/printer_config.dart';

// Native Splash importu
import 'package:flutter_native_splash/flutter_native_splash.dart';

// Yerelleştirme
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

// Provider
import 'package:provider/provider.dart';
import 'providers/language_provider.dart';

// Platform Kontrolü
import 'dart:async';

// Global Keys - Thundering Herd çözümü için RouteObserver eklendi
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final RouteObserver<PageRoute> routeObserver = RouteObserver<PageRoute>();

// 🔥 FINAL NavigatorSafeZone - Notification Recovery & Duplicate Prevention
class NavigatorSafeZone {
  static bool _isNavigatorBusy = false;
  static int _operationCount = 0;
  static Timer? _busyTimer;
  static final Set<String> _activeOperations = <String>{};
  static bool _isNavigating = false; // 🔥 Navigation guard

  static bool get isBusy => _isNavigatorBusy;
  static bool get isNavigating => _isNavigating;
  static Set<String> get activeOperations => Set.from(_activeOperations);

  static void markBusy(String operation) {
    // Duplicate operations önleme
    if (_activeOperations.contains(operation)) {
      debugPrint('[NavigatorSafeZone] ⚠️ Operation $operation already active, skipping...');
      return;
    }
    
    _activeOperations.add(operation);
    _operationCount++;
    _isNavigatorBusy = true;
    _busyTimer?.cancel();

    debugPrint('[NavigatorSafeZone] Navigator marked busy: $operation (count: $_operationCount)');
    debugPrint('[NavigatorSafeZone] Active operations: ${_activeOperations.join(", ")}');

    // 3 saniye sonra otomatik unlock
    _busyTimer = Timer(const Duration(seconds: 3), () {
      forceUnlock('timeout');
    });
  }

  static void markFree(String operation) {
    _activeOperations.remove(operation);
    _operationCount = _operationCount > 0 ? _operationCount - 1 : 0;

    if (_operationCount <= 0) {
      _operationCount = 0;
      _isNavigatorBusy = false;
      _activeOperations.clear();
      _busyTimer?.cancel();
      debugPrint('[NavigatorSafeZone] Navigator marked free: $operation');
    } else {
      debugPrint('[NavigatorSafeZone] Navigator still busy: $operation (remaining: $_operationCount)');
      debugPrint('[NavigatorSafeZone] Remaining operations: ${_activeOperations.join(", ")}');
    }
  }

  static void forceUnlock(String reason) {
    if (_isNavigatorBusy) {
      debugPrint('[NavigatorSafeZone] 🚨 FORCE unlocking due to: $reason');
      debugPrint('[NavigatorSafeZone] Cleared operations: ${_activeOperations.join(", ")}');
    }
    
    _isNavigatorBusy = false;
    _operationCount = 0;
    _activeOperations.clear();
    _busyTimer?.cancel();
    debugPrint('[NavigatorSafeZone] Navigator auto-unlocked after timeout');
  }

  // 🔥 CRITICAL: Navigation state guard with notification recovery
  static void setNavigating(bool navigating) {
    _isNavigating = navigating;
    debugPrint('[NavigatorSafeZone] Navigation state: ${navigating ? "🟡 ACTIVE" : "🟢 IDLE"}');
    
    // 🔥 CRITICAL FIX: Process pending notifications when navigation becomes free
    if (!navigating && !_isNavigatorBusy) {
      Timer(Duration(milliseconds: 50), () {
        try {
          globalHandler.GlobalNotificationHandler.instance.processPendingNotifications();
          debugPrint('[NavigatorSafeZone] ✅ Triggered pending notification processing');
        } catch (e) {
          debugPrint('[NavigatorSafeZone] ❌ Error processing pending notifications: $e');
        }
      });
    }
  }

  static bool canNavigate() {
    final canNav = !_isNavigatorBusy && !_isNavigating;
    if (!canNav) {
      debugPrint('[NavigatorSafeZone] ❌ Navigation blocked - Busy: $_isNavigatorBusy, Navigating: $_isNavigating');
    }
    return canNav;
  }

  // Health check
  static void healthCheck() {
    debugPrint('[NavigatorSafeZone] 🏥 Health Check:');
    debugPrint('  - Busy: $_isNavigatorBusy');
    debugPrint('  - Navigating: $_isNavigating');
    debugPrint('  - Operation Count: $_operationCount');
    debugPrint('  - Active Operations: ${_activeOperations.isEmpty ? "None" : _activeOperations.join(", ")}');
  }
}

// 🔥 GELİŞTİRİLMİŞ BuildLockManager - Duplicate Locks Önleyici
class BuildLockManager {
  static bool _isBuildLocked = false;
  static final Set<String> _activeLocks = <String>{};
  static Timer? _unlockTimer;

  static bool get isLocked => _isBuildLocked;
  static Set<String> get activeLocks => Set.from(_activeLocks);

  static void lockBuild(String reason) {
    // Duplicate lock önleme
    if (_activeLocks.contains(reason)) {
      debugPrint('[BuildLockManager] ⚠️ Lock $reason already active, skipping...');
      return;
    }
    
    _activeLocks.add(reason);
    if (!_isBuildLocked) {
      _isBuildLocked = true;
      debugPrint('[BuildLockManager] Build locked by: $reason');
      
      // 2 saniye sonra otomatik açılma
      _unlockTimer?.cancel();
      _unlockTimer = Timer(const Duration(seconds: 2), () {
        forceUnlock('timeout');
      });
    }
    
    debugPrint('[BuildLockManager] Active locks: ${_activeLocks.join(", ")}');
  }

  static void unlockBuild(String reason) {
    _activeLocks.remove(reason);
    if (_activeLocks.isEmpty && _isBuildLocked) {
      _isBuildLocked = false;
      _unlockTimer?.cancel();
      debugPrint('[BuildLockManager] Build unlocked by: $reason');
    } else if (_isBuildLocked) {
      debugPrint('[BuildLockManager] Build still locked by: ${_activeLocks.join(", ")}');
    }
  }

  static void forceUnlock(String reason) {
    if (_isBuildLocked) {
      debugPrint('[BuildLockManager] 🚨 FORCE unlocking due to: $reason');
      debugPrint('[BuildLockManager] Cleared locks: ${_activeLocks.join(", ")}');
      _activeLocks.clear();
      _isBuildLocked = false;
      _unlockTimer?.cancel();
      debugPrint('[BuildLockManager] Build FORCE unlocked by: $reason');
    }
  }

  static bool shouldSkipBuild() {
    return _isBuildLocked;
  }

  static void healthCheck() {
    debugPrint('[BuildLockManager] 🏥 Health Check:');
    debugPrint('  - Locked: $_isBuildLocked');
    debugPrint('  - Active Locks: ${_activeLocks.isEmpty ? "None" : _activeLocks.join(", ")}');
  }
}

Future<void> main() async {
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  await dotenv.load(fileName: ".env");
  await Hive.initFlutter();
  Hive.registerAdapter(SyncQueueItemAdapter());
  Hive.registerAdapter(PrinterConfigAdapter());

  // Servisleri başlat
  await CacheService.instance.initialize();
  ConnectivityService.instance.initialize();
  SyncService.instance.initialize();

  // Zaman dilimini ayarla
  tz.initializeTimeZones();
  try {
    final String timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
  } catch (e) {
    print("Zaman dilimi alınamadı: $e");
    tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));
  }

  // Firebase'i başlat
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Uygulamayı çalıştır
  runApp(
    ChangeNotifierProvider(
      create: (_) => LanguageProvider()..loadLocale(),
      child: const MyApp(),
    ),
  );

  // Uygulama genelindeki bildirim dinleyicisini başlat.
  globalHandler.GlobalNotificationHandler.initialize();

  // Splash screen'i kaldır
  await Future.delayed(const Duration(seconds: 1));
  FlutterNativeSplash.remove();
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _isAppReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _isAppReady = true);
        // Başlangıçta uygulamanın ön planda olduğunu varsay
        globalHandler.GlobalNotificationHandler.updateAppLifecycleState(AppLifecycleState.resumed);
        ConnectionManager().startMonitoring();
        debugPrint('[MyApp] Connection manager başlatıldı');
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isAppReady) return;
    super.didChangeAppLifecycleState(state);
    
    // GlobalNotificationHandler'a lifecycle değişikliğini bildir
    try {
      globalHandler.GlobalNotificationHandler.updateAppLifecycleState(state);
    } catch (e) {
      debugPrint('GlobalNotificationHandler lifecycle update failed: $e');
    }
    
    // 🔥 DÜZELTİLMİŞ: Duplicate operations önleme
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
        debugPrint('[MyApp] Uygulama inactive durumda');
        NavigatorSafeZone.markBusy('app_inactive');
        BuildLockManager.lockBuild('app_inactive');
        break;
        
      case AppLifecycleState.resumed:
        debugPrint('[MyApp] Uygulama ön plana geldi, kilitler açılıyor ve bağlantılar kontrol ediliyor...');
        NavigatorSafeZone.markFree('app_resumed');
        
        // Kademeli unlock - race condition önleme
        Timer(const Duration(milliseconds: 300), () {
          BuildLockManager.unlockBuild('app_inactive');
        });
        
        // 🔥 CRITICAL: Notification processing - daha geç başlat
        Timer(const Duration(milliseconds: 800), () {
          try {
            globalHandler.GlobalNotificationHandler.instance.processPendingNotifications();
          } catch (e) {
            debugPrint('Failed to process pending notifications: $e');
          }
        });
        
        // Connection check - en son
        Timer(const Duration(seconds: 1), () {
          _checkConnectionsAfterResume();
        });
        break;
        
      case AppLifecycleState.detached:
        debugPrint('[MyApp] Uygulama kapatıldı (detached)');
        NavigatorSafeZone.forceUnlock('app_detached');
        BuildLockManager.forceUnlock('app_detached');
        break;
        
      default:
        break;
    }
  }

  void _checkConnectionsAfterResume() {
    try {
      final token = UserSession.token;
      if (token.isNotEmpty) {
        final socketService = SocketService.instance;
        if (!socketService.isConnected) {
          debugPrint('[MyApp] Token bulundu, socket yeniden bağlanıyor...');
          socketService.connectAndListen();
        }

        if (!ConnectionManager().isMonitoring) {
          ConnectionManager().startMonitoring();
        } else {
          ConnectionManager().forceReconnect();
        }
      } else {
        debugPrint('[MyApp] Token bulunamadı, socket bağlantısı yapılmayacak');
      }
    } catch (e) {
      debugPrint('❌ [MyApp] Bağlantı kontrolü hatası: $e');
    }
  }

  @override
  void dispose() {
    debugPrint('[MyApp] Dispose ediliyor...');
    WidgetsBinding.instance.removeObserver(this);
    
    NavigatorSafeZone.forceUnlock('app_dispose');
    BuildLockManager.forceUnlock('app_dispose');

    ConnectionManager().stopMonitoring();
    SocketService.instance.dispose();
    globalHandler.GlobalNotificationHandler.instance.dispose();

    super.dispose();
    debugPrint('[MyApp] Dispose tamamlandı');
  }

  @override
  Widget build(BuildContext context) {
    final languageProvider = Provider.of<LanguageProvider>(context);

    if (BuildLockManager.shouldSkipBuild()) {
      debugPrint('[MyApp] 🔒 Build locked - Active locks: ${BuildLockManager.activeLocks.join(", ")}');
      return MaterialApp(
        title: 'OrderAI',
        debugShowCheckedModeBanner: false,
        home: Container(
          color: Colors.blue.shade900,
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 16),
                Text(
                  'Sistem hazırlanıyor...',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'OrderAI',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      navigatorObservers: [routeObserver],
      locale: languageProvider.currentLocale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('tr', ''),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue,
        cardTheme: CardTheme(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}