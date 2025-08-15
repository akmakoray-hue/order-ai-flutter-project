// lib/screens/manage_staff_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart';
import 'add_edit_staff_screen.dart';
import '../services/user_session.dart';
import 'subscription_screen.dart';

class ManageStaffScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const ManageStaffScreen(
      {Key? key, required this.token, required this.businessId})
      : super(key: key);

  @override
  _ManageStaffScreenState createState() => _ManageStaffScreenState();
}

class _ManageStaffScreenState extends State<ManageStaffScreen> {
  bool _isLoading = true;
  List<dynamic> _staffList = [];
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ManageStaffScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'manage_staff_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchStaffList();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ManageStaffScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'manage_staff_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchStaffList();
        });
      }
    });

    _fetchStaffList();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> _fetchStaffList() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      final staff = await ApiService.getStaffList(widget.token);
      if (mounted) {
        setState(() {
          _staffList = staff;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _deleteStaff(int staffId) async {
    final l10n = AppLocalizations.of(context)!;
    bool? confirmDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(l10n.manageStaffDialogDeleteTitle),
          content: Text(l10n.manageStaffDialogDeleteContent),
          actions: <Widget>[
            TextButton(
              child: Text(l10n.dialogButtonCancel),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: Text(l10n.dialogButtonDelete, style: const TextStyle(color: Colors.red)),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );

    if (confirmDelete != true) return;

    try {
      await ApiService.deleteStaff(widget.token, staffId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l10n.manageStaffSuccessDelete),
            backgroundColor: Colors.green),
      );
      _fetchStaffList(); // Listeyi yenile
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l10n.manageStaffErrorDelete(e.toString())),
            backgroundColor: Colors.red),
      );
    }
  }

  void _showLimitReachedDialog(String message) {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.dialogLimitReachedTitle),
        content: Text(message),
        actions: [
          TextButton(
            child: Text(l10n.dialogButtonLater),
            onPressed: () => Navigator.of(ctx).pop(),
          ),
          ElevatedButton(
            child: Text(l10n.dialogButtonUpgradePlan),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
            },
          ),
        ],
      ),
    );
  }

  // === DEĞİŞİKLİK: Metot artık 'limits' parametresi alıyor ===
  Future<void> _navigateToAddEditStaffScreen({dynamic staff, required SubscriptionLimits limits}) async {
    final l10n = AppLocalizations.of(context)!;
    // === DEĞİŞİKLİK: Statik `UserSession.maxStaff` yerine dinamik `limits.maxStaff` kullanılıyor ===
    if (staff == null && _staffList.length >= limits.maxStaff) {
      _showLimitReachedDialog(
        l10n.manageStaffErrorLimitExceeded(limits.maxStaff.toString())
      );
      return;
    }

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddEditStaffScreen(
          token: widget.token,
          businessId: widget.businessId,
          staff: staff,
        ),
      ),
    );
    if (result == true) {
      _fetchStaffList();
    }
  }
  
  Widget _buildStaffCard(dynamic staff, AppLocalizations l10n) {
    final String fullName = "${staff['first_name'] ?? ''} ${staff['last_name'] ?? ''}".trim();
    final String displayName = fullName.isNotEmpty ? fullName : staff['username'] ?? l10n.manageStaffUnknownStaff;
    final bool isActive = staff['is_active'] ?? false;

    return Card(
      color: Colors.white.withOpacity(0.85),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive ? Colors.green.withOpacity(0.5) : Colors.red.withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: InkWell(
        onTap: () => _navigateToAddEditStaffScreen(staff: staff, limits: UserSession.limitsNotifier.value), // Mevcut state'i yolla
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: Theme.of(context).primaryColor.withOpacity(0.2),
                        child: const Icon(Icons.person_outline, size: 32, color: Colors.indigo),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        displayName,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        staff['user_type'] == 'kitchen_staff' ? l10n.roleKitchenStaff : l10n.roleStaff,
                        style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              color: Colors.black.withOpacity(0.05),
              padding: const EdgeInsets.symmetric(horizontal: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Chip(
                    label: Text(isActive ? l10n.manageCampaignsStatusActive : l10n.manageCampaignsStatusInactive),
                    backgroundColor: isActive ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                    labelStyle: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isActive ? Colors.green.shade800 : Colors.red.shade800,
                    ),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, size: 20, color: Colors.blueAccent),
                        tooltip: l10n.tooltipEdit,
                        onPressed: () => _navigateToAddEditStaffScreen(staff: staff, limits: UserSession.limitsNotifier.value), // Mevcut state'i yolla
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 20, color: Colors.redAccent),
                        tooltip: l10n.tooltipDelete,
                        onPressed: () => _deleteStaff(staff['id']),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.manageStaffTitle,
            style:
                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue.shade900, Colors.blue.shade400],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          // === DEĞİŞİKLİK: IconButton, ValueListenableBuilder ile sarmalandı ===
          ValueListenableBuilder<SubscriptionLimits>(
            valueListenable: UserSession.limitsNotifier,
            builder: (context, limits, child) {
              // Mevcut personel sayısı, abonelik limitinden az ise buton aktiftir.
              final bool canAddMore = _staffList.length < limits.maxStaff;

              return IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: l10n.manageStaffTooltipAdd,
                // Butonun aktif olup olmadığı `canAddMore` değişkenine bağlıdır.
                onPressed: _isLoading || !canAddMore
                    ? null
                    : () => _navigateToAddEditStaffScreen(limits: limits),
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blue.shade900.withOpacity(0.9),
              Colors.blue.shade400.withOpacity(0.8)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _errorMessage.isNotEmpty
                ? Center(
                    child: Text(_errorMessage,
                        style: const TextStyle(color: Colors.redAccent)))
                : _staffList.isEmpty
                    ? Center(
                        child: Text(l10n.manageStaffNoStaff,
                            style: const TextStyle(color: Colors.white70)))
                    : RefreshIndicator(
                        onRefresh: _fetchStaffList,
                        child: GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 250,
                              childAspectRatio: 0.9,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16
                          ),
                          itemCount: _staffList.length,
                          itemBuilder: (context, index) {
                            final staff = _staffList[index];
                            return _buildStaffCard(staff, l10n);
                          },
                        ),
                      ),
      ),
    );
  }
}