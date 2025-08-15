// lib/screens/pager_management_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/bluetooth_pager_service.dart';
import '../services/pager_service.dart'; // Servisi import ediyoruz
import '../models/pager_device_model.dart';
import '../services/user_session.dart';
import '../utils/notifiers.dart';
import 'package:flutter/foundation.dart';

class PagerManagementScreen extends StatefulWidget {
  const PagerManagementScreen({Key? key}) : super(key: key);

  @override
  State<PagerManagementScreen> createState() => _PagerManagementScreenState();
}

class _PagerManagementScreenState extends State<PagerManagementScreen> {
  late BluetoothPagerService _blePagerService;
  // === YENİ: Servis örneği oluşturuluyor ===
  final PagerService _pagerService = PagerService.instance;
  
  List<PagerSystemDevice> _systemPagers = [];
  bool _isLoadingSystemPagers = true;
  String _systemPagersErrorMessage = '';
  String _bleConnectionStatusMessage = '';

  final TextEditingController _newPagerIdController = TextEditingController();
  final TextEditingController _newPagerNameController = TextEditingController();
  final TextEditingController _newPagerNotesController = TextEditingController();
  final GlobalKey<FormState> _addPagerFormKey = GlobalKey<FormState>();
  bool _isAddingPager = false;

  @override
  void initState() {
    super.initState();
    _blePagerService = BluetoothPagerService();
    _blePagerService.addListener(_onBleServiceUpdate);
    pagerStatusUpdateNotifier.addListener(_handlePagerStatusSocketUpdate);
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[PagerManagementScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'pager_management_screen';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchSystemPagers();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[PagerManagementScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'pager_management_screen_active';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchSystemPagers();
        });
      }
    });
    
    // Servis başlatma işlemi didChangeDependencies'e taşındı.
  }
  
  // YENİ: didChangeDependencies eklendi
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // l10n nesnesini burada alıp servisi başlatıyoruz.
    final l10n = AppLocalizations.of(context)!;
    _pagerService.init(l10n);
    _fetchSystemPagers();
  }

  @override
  void dispose() {
    _blePagerService.removeListener(_onBleServiceUpdate);
    _blePagerService.dispose();
    pagerStatusUpdateNotifier.removeListener(_handlePagerStatusSocketUpdate);
    _newPagerIdController.dispose();
    _newPagerNameController.dispose();
    _newPagerNotesController.dispose();
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  void _onBleServiceUpdate() {
    if (mounted) {
      setState(() {
        _bleConnectionStatusMessage = _blePagerService.connectionStatus;
      });
    }
  }

  void _handlePagerStatusSocketUpdate() {
    final data = pagerStatusUpdateNotifier.value;
    if (data != null && mounted) {
      debugPrint("PagerManagementScreen: Pager status update from socket: ${data['pager_id']} - ${data['message']}");
      _fetchSystemPagers();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) pagerStatusUpdateNotifier.value = null;
      });
    }
  }

  Future<void> _fetchSystemPagers() async {
    if (!mounted) return;
    setState(() {
      _isLoadingSystemPagers = true;
      _systemPagersErrorMessage = '';
    });
    try {
      // GÜNCELLEME: Servis metodu instance üzerinden çağrılıyor
      final pagers = await _pagerService.fetchPagers(UserSession.token);
      if (mounted) {
        setState(() => _systemPagers = pagers);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _systemPagersErrorMessage = e.toString().replaceFirst("Exception: ", ""));
      }
    } finally {
      if (mounted) setState(() => _isLoadingSystemPagers = false);
    }
  }

  // ... _startBleScan, _sendTestNotificationToSystemPager, _getLocalizedPagerStatus metotları aynı kalabilir ...
  Future<void> _startBleScan() async {
    await _blePagerService.startScan(scanForAllServices: true);
  }

  Future<void> _sendTestNotificationToSystemPager(PagerSystemDevice sysPager) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    bool success = await _blePagerService.notifySpecificPagerOrderReady(
      sysPager.deviceId,
      "TEST",
      sysPager.name ?? l10n.pagerDefaultDeviceName,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(success ? l10n.pagerTestNotificationSuccess(sysPager.name ?? sysPager.deviceId) : l10n.pagerTestNotificationFailure),
        backgroundColor: success ? Colors.green : Colors.red,
      ));
    }
  }
  
  String _getLocalizedPagerStatus(String statusKey, AppLocalizations l10n) {
      switch (statusKey) {
          case 'available': return l10n.pagerStatusAvailable;
          case 'in_use': return l10n.pagerStatusInUse;
          case 'charging': return l10n.pagerStatusCharging;
          case 'low_battery': return l10n.pagerStatusLowBattery;
          case 'out_of_service': return l10n.pagerStatusOutOfService;
          default: return statusKey.toUpperCase();
      }
  }
  
  Future<void> _updatePagerStatus(PagerSystemDevice pager, String newStatus) async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final String statusDisplayName = _getLocalizedPagerStatus(newStatus, l10n);
    final String pagerDisplayName = pager.name ?? pager.deviceId;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.pagerDialogUpdateStatusTitle),
        content: Text(l10n.pagerDialogUpdateStatusContent(pagerDisplayName, statusDisplayName)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l10n.dialogButtonCancel)),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.pagerButtonConfirmChange)),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _isLoadingSystemPagers = true);
    try {
      // GÜNCELLEME: Servis metodu instance üzerinden çağrılıyor
      await _pagerService.updatePager(UserSession.token, pager.id, status: newStatus);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.pagerInfoStatusUpdated), backgroundColor: Colors.green,));
        await _fetchSystemPagers();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.pagerErrorStatusUpdate(e.toString())), backgroundColor: Colors.red,));
      }
    } finally {
      if (mounted) setState(() => _isLoadingSystemPagers = false);
    }
  }

  Future<void> _showAddPagerDialog() async {
    final l10n = AppLocalizations.of(context)!;
    _newPagerIdController.clear();
    _newPagerNameController.clear();
    _newPagerNotesController.clear();
    String dialogMessage = '';
    bool isDialogSubmitting = false;

    await showDialog(
      context: context,
      barrierDismissible: !isDialogSubmitting,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext)!;
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(dialogL10n.pagerDialogAddTitle),
            content: Form(
              key: _addPagerFormKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      icon: Icon(Icons.bluetooth_searching, color: Theme.of(context).primaryColor),
                      label: Text(_blePagerService.isScanning ? dialogL10n.pagerButtonScanning : dialogL10n.pagerButtonScanAndSelect),
                      onPressed: _blePagerService.isScanning ? null : () async {
                        setDialogState(() {});
                        await _blePagerService.startScan(scanForAllServices: true);
                        await Future.delayed(const Duration(milliseconds: 500));
                        if (_blePagerService.discoveredPagers.isNotEmpty && mounted) {
                          final PagerDevice? selectedBleDevice = await showModalBottomSheet<PagerDevice>(
                            context: dialogContext,
                            builder: (modalContext) {
                              final modalL10n = AppLocalizations.of(modalContext)!;
                              return SizedBox(
                                height: MediaQuery.of(context).size.height * 0.4,
                                child: Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Text(modalL10n.pagerDiscoveredDevicesTitle, style: Theme.of(context).textTheme.titleMedium),
                                    ),
                                    Expanded(
                                      child: ListView.builder(
                                        itemCount: _blePagerService.discoveredPagers.length,
                                        itemBuilder: (ctx, idx) {
                                          final p = _blePagerService.discoveredPagers[idx];
                                          return ListTile(
                                            title: Text(p.name.isNotEmpty ? p.name : modalL10n.pagerUnknownDevice),
                                            subtitle: Text(p.id),
                                            onTap: () => Navigator.pop(ctx, p),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                          if (selectedBleDevice != null) {
                            setDialogState(() {
                              _newPagerIdController.text = selectedBleDevice.id;
                              if (selectedBleDevice.name.isNotEmpty && selectedBleDevice.name != dialogL10n.pagerUnknownDevice) {
                                _newPagerNameController.text = selectedBleDevice.name;
                              } else {
                                _newPagerNameController.clear();
                              }
                            });
                          }
                        } else if (mounted) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(content: Text(dialogL10n.pagerInfoNoBleDevicesFound), duration: const Duration(seconds: 2)),
                          );
                        }
                        setDialogState(() {});
                      },
                    ),
                    TextFormField(
                      controller: _newPagerIdController,
                      decoration: InputDecoration(labelText: dialogL10n.pagerLabelDeviceIdRequired),
                      validator: (v) => (v == null || v.trim().isEmpty) ? dialogL10n.pagerValidatorDeviceIdRequired : null,
                    ),
                    TextFormField(
                      controller: _newPagerNameController,
                      decoration: InputDecoration(labelText: dialogL10n.pagerLabelDeviceNameOptional),
                    ),
                    TextFormField(
                      controller: _newPagerNotesController,
                      decoration: InputDecoration(labelText: dialogL10n.pagerLabelNotesOptional),
                      maxLines: 2,
                    ),
                    if (dialogMessage.isNotEmpty) Padding(padding: const EdgeInsets.only(top:8.0), child: Text(dialogMessage, style: const TextStyle(color: Colors.red))),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogL10n.dialogButtonCancel)),
              ElevatedButton(
                onPressed: isDialogSubmitting ? null : () async {
                  if (_addPagerFormKey.currentState!.validate()) {
                    setDialogState(() {
                      isDialogSubmitting = true;
                      dialogMessage = '';
                    });
                    try {
                      // GÜNCELLEME: Servis metodu instance üzerinden çağrılıyor
                      await _pagerService.createPager(
                        UserSession.token,
                        UserSession.businessId!,
                        _newPagerIdController.text.trim(),
                        name: _newPagerNameController.text.trim(),
                        notes: _newPagerNotesController.text.trim(),
                      );
                      if (mounted) Navigator.pop(dialogContext);
                      await _fetchSystemPagers();
                    } catch (e) {
                      setDialogState(() => dialogMessage = e.toString().replaceFirst("Exception: ", ""));
                    } finally {
                      if (mounted) setDialogState(() => isDialogSubmitting = false);
                    }
                  }
                },
                child: isDialogSubmitting ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(dialogL10n.pagerButtonAdd),
              ),
            ],
          );
        });
      },
    );
  }

  // build metodu ve _buildPagerCard metodu içinde l10n kullanımı doğru olduğu için aynı kalabilir.
  // Sadece onSelected içindeki silme işlemi güncellenmelidir.
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final List<PagerSystemDevice> availablePagers = _systemPagers.where((p) => p.status == 'available').toList();
    final List<PagerSystemDevice> inUsePagers = _systemPagers.where((p) => p.status == 'in_use').toList();
    final List<PagerSystemDevice> otherStatusPagers = _systemPagers.where((p) => p.status != 'available' && p.status != 'in_use').toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          l10n.pagerManagementTitle,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blueGrey.shade700, Colors.blueGrey.shade900],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.white),
            tooltip: l10n.pagerTooltipAdd,
            onPressed: _isLoadingSystemPagers ? null : _showAddPagerDialog,
          ),
          IconButton(
            icon: Icon(
              _blePagerService.isScanning ? Icons.bluetooth_searching_rounded : Icons.bluetooth_disabled_outlined,
              color: Colors.white,
            ),
            tooltip: _blePagerService.isScanning ? l10n.pagerButtonScanning : l10n.pagerTooltipScanBle,
            onPressed: _blePagerService.isScanning ? null : _startBleScan,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _isLoadingSystemPagers ? null : _fetchSystemPagers,
            tooltip: l10n.pagerTooltipRefreshList,
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blueGrey.shade800.withOpacity(0.9),
              Colors.blueGrey.shade900.withOpacity(0.95),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Card(
                color: Colors.white.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    _bleConnectionStatusMessage.isNotEmpty ? l10n.pagerStatusBle(_bleConnectionStatusMessage) : l10n.pagerStatusBleWaiting,
                    style: TextStyle(color: _blePagerService.isConnected ? Colors.greenAccent.shade100 : Colors.orangeAccent.shade100, fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            if (_isLoadingSystemPagers)
              const Expanded(child: Center(child: CircularProgressIndicator(color: Colors.white)))
            else if (_systemPagersErrorMessage.isNotEmpty && _systemPagers.isEmpty)
              Expanded(child: Center(child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(_systemPagersErrorMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16)),
              )))
            else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _fetchSystemPagers,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    children: [
                      if (_systemPagers.isEmpty && _systemPagersErrorMessage.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: Center(child: Text(l10n.pagerNoDevicesFound, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.white70))),
                          ),
                      if (inUsePagers.isNotEmpty) ...[
                        ListTile(title: Text(l10n.pagerHeaderInUse, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent))),
                        ...inUsePagers.map((pager) => _buildPagerCard(pager, context)),
                        const Divider(color: Colors.white24),
                      ],
                      if (availablePagers.isNotEmpty) ...[
                        ListTile(title: Text(l10n.pagerHeaderAvailable, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent))),
                        ...availablePagers.map((pager) => _buildPagerCard(pager, context)),
                        const Divider(color: Colors.white24),
                      ],
                      if (otherStatusPagers.isNotEmpty) ...[
                        ListTile(title: Text(l10n.pagerHeaderOtherStatus, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey))),
                        ...otherStatusPagers.map((pager) => _buildPagerCard(pager, context)),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagerCard(PagerSystemDevice pager, BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bool isConnectedToThisPager = _blePagerService.isConnected && _blePagerService.connectedDevice?.remoteId.toString() == pager.deviceId;
    Color cardBackgroundColor = Colors.blueGrey.shade700.withOpacity(0.8);
    Color borderColor = Colors.white.withOpacity(0.2);
    IconData statusIconData = Icons.help_outline;
    final String statusDisplay = _getLocalizedPagerStatus(pager.status, l10n);

    switch (pager.status) {
      case 'available':
        cardBackgroundColor = Colors.green.shade800.withOpacity(0.75);
        borderColor = Colors.greenAccent.shade200;
        statusIconData = Icons.check_circle_outline;
        break;
      case 'in_use':
        cardBackgroundColor = Colors.orange.shade800.withOpacity(0.75);
        borderColor = Colors.orangeAccent.shade200;
        statusIconData = Icons.notifications_active_outlined;
        break;
      case 'charging':
        cardBackgroundColor = Colors.blue.shade700.withOpacity(0.75);
        borderColor = Colors.lightBlueAccent.shade100;
        statusIconData = Icons.battery_charging_full_outlined;
        break;
      case 'out_of_service':
        cardBackgroundColor = Colors.red.shade800.withOpacity(0.75);
        borderColor = Colors.redAccent.shade100;
        statusIconData = Icons.phonelink_off_outlined;
        break;
      case 'low_battery':
        cardBackgroundColor = Colors.deepOrange.shade700.withOpacity(0.75);
        borderColor = Colors.deepOrangeAccent.shade100;
        statusIconData = Icons.battery_alert_outlined;
        break;
    }

    return Card(
      color: cardBackgroundColor,
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      elevation: isConnectedToThisPager ? 5 : 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isConnectedToThisPager ? Colors.tealAccent.shade400 : borderColor, width: 1.5)
      ),
      child: ListTile(
        leading: Icon(
          isConnectedToThisPager ? Icons.bluetooth_connected_rounded : Icons.devices_other_rounded,
          color: isConnectedToThisPager ? Colors.tealAccent.shade200 : Colors.white.withOpacity(0.8),
          size: 30,
        ),
        title: Text(pager.name ?? pager.deviceId, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white.withOpacity(0.95), fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.pagerCardDeviceId(pager.deviceId), style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7))),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(statusIconData, size: 14, color: Colors.white.withOpacity(0.85)),
                const SizedBox(width: 4),
                Text(l10n.pagerCardStatus(statusDisplay), style: TextStyle(color: Colors.white.withOpacity(0.9), fontWeight: FontWeight.w500, fontSize: 12)),
              ],
            ),
            if(pager.currentOrderId != null) Text(l10n.pagerCardOrderId(pager.currentOrderId.toString()), style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7))),
            if(pager.notes != null && pager.notes!.isNotEmpty) Text(l10n.pagerCardNotes(pager.notes!), style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.7), fontStyle: FontStyle.italic), overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: Colors.white.withOpacity(0.8)),
          color: Colors.blueGrey.shade800,
          itemBuilder: (BuildContext context) {
            final popupL10n = AppLocalizations.of(context)!;
            return <PopupMenuEntry<String>>[
              if (isConnectedToThisPager && _blePagerService.pagerCommandCharacteristic != null)
                  PopupMenuItem<String>(value: 'test_notification', child: Text(popupL10n.pagerMenuSendTestNotification, style: const TextStyle(color: Colors.white))),
              if (isConnectedToThisPager && _blePagerService.pagerCommandCharacteristic != null) const PopupMenuDivider(),
              if (pager.status != 'available')
                  PopupMenuItem<String>(value: 'available', child: Text(popupL10n.pagerMenuMarkAsAvailable, style: const TextStyle(color: Colors.white))),
              if (pager.status != 'charging')
                  PopupMenuItem<String>(value: 'charging', child: Text(popupL10n.pagerMenuMarkAsCharging, style: const TextStyle(color: Colors.white))),
              if (pager.status != 'out_of_service')
                  PopupMenuItem<String>(value: 'out_of_service', child: Text(popupL10n.pagerMenuMarkAsOutOfService, style: const TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              PopupMenuItem<String>(value: 'delete', child: Text(popupL10n.pagerMenuDeleteFromSystem, style: const TextStyle(color: Colors.redAccent))),
            ];
          },
          onSelected: (String value) async {
            if (value == 'test_notification') {
              _sendTestNotificationToSystemPager(pager);
            } else if (value == 'delete') {
              final pagerDisplayName = pager.name ?? pager.deviceId;
              final confirmDelete = await showDialog<bool>(context: context, builder: (ctx) {
                final dialogL10n = AppLocalizations.of(ctx)!;
                return AlertDialog(
                  title: Text(dialogL10n.pagerDialogDeleteTitle), 
                  content: Text(dialogL10n.pagerDialogDeleteContent(pagerDisplayName)), 
                  actions: [
                    TextButton(onPressed:() => Navigator.pop(ctx, false), child: Text(dialogL10n.dialogButtonCancel)), 
                    TextButton(onPressed:()=> Navigator.pop(ctx, true), child: Text(dialogL10n.dialogButtonDelete, style: const TextStyle(color: Colors.red)))
                  ]
                );
              });
              if(confirmDelete == true && mounted) {
                try {
                  // GÜNCELLEME: Servis metodu instance üzerinden çağrılıyor
                  await _pagerService.deletePager(UserSession.token, pager.id);
                  await _fetchSystemPagers();
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.pagerInfoDeviceDeleted), backgroundColor: Colors.orange));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.pagerErrorDeleting(e.toString())), backgroundColor: Colors.red));
                }
              }
            } else {
              _updatePagerStatus(pager, value);
            }
          },
        ),
      ),
    );
  }
}