// lib/utils/notifiers.dart

import 'package:flutter/material.dart';

final ValueNotifier<bool> shouldRefreshTablesNotifier = ValueNotifier<bool>(false);
final ValueNotifier<Map<String, dynamic>?> newOrderNotificationDataNotifier = ValueNotifier(null);
final ValueNotifier<Map<String, dynamic>?> orderStatusUpdateNotifier = ValueNotifier(null);
final ValueNotifier<Map<String, dynamic>?> waitingListChangeNotifier = ValueNotifier(null);
final ValueNotifier<bool> shouldRefreshWaitingCountNotifier = ValueNotifier<bool>(false);
final ValueNotifier<Map<String, dynamic>?> pagerStatusUpdateNotifier = ValueNotifier(null);
final ValueNotifier<Map<String, dynamic>?> informationalNotificationNotifier = ValueNotifier(null);
final ValueNotifier<String?> syncStatusMessageNotifier = ValueNotifier(null);
final ValueNotifier<bool> stockAlertNotifier = ValueNotifier<bool>(false);
final ValueNotifier<Map<String, dynamic>?> kdsUpdateNotifier = ValueNotifier(null);