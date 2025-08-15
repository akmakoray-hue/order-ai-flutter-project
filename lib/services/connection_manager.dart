// lib/services/connection_manager.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'socket_service.dart';
import 'user_session.dart';

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;
  ConnectionManager._internal();

  Timer? _connectionCheckTimer;
  bool _isMonitoring = false;
  bool _isCheckingConnection = false;
  DateTime? _lastConnectionCheck;

  void startMonitoring() {
    if (_isMonitoring) return;
    
    print('[ConnectionManager] Bağlantı izleme başlatılıyor...');
    _isMonitoring = true;
    _connectionCheckTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      _checkConnections();
    });
  }

  void _checkConnections() {
    if (_isCheckingConnection) return;
    
    _isCheckingConnection = true;
    
    try {
      _lastConnectionCheck = DateTime.now();
      final socketService = SocketService.instance;
      
      final isActuallyConnected = socketService.checkConnection();
      
      if (!isActuallyConnected) {
        print('⚠️ [ConnectionManager] Socket bağlantısı kopuk, yeniden bağlanılıyor...');
        
        // Token kontrol et ve bağlan
        if (UserSession.token.isNotEmpty) {
          socketService.connectAndListen();
        } else {
          print('❌ [ConnectionManager] Token bulunamadı, yeniden bağlanma iptal edildi');
        }
      } else {
        if (kDebugMode) {
          print('✅ [ConnectionManager] Bağlantılar normal');
        }
      }
    } catch (e) {
      print('❌ [ConnectionManager] Bağlantı kontrolü hatası: $e');
    } finally {
      _isCheckingConnection = false;
    }
  }

  void forceReconnect() {
    print('[ConnectionManager] Zorla yeniden bağlanma tetiklendi');
    _checkConnections();
  }

  void stopMonitoring() {
    print('[ConnectionManager] Bağlantı izleme durduruluyor...');
    _isMonitoring = false;
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
  }

  bool get isMonitoring => _isMonitoring;
  DateTime? get lastConnectionCheck => _lastConnectionCheck;
}