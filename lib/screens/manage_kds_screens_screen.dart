// lib/screens/manage_kds_screens_screen.dart
import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/kds_management_service.dart';
import '../models/kds_screen_model.dart';
import '../widgets/admin/admin_confirmation_dialog.dart';
import '../services/user_session.dart';
import '../screens/subscription_screen.dart';

class ManageKdsScreensScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const ManageKdsScreensScreen({
    Key? key,
    required this.token,
    required this.businessId,
  }) : super(key: key);

  @override
  _ManageKdsScreensScreenState createState() => _ManageKdsScreensScreenState();
}

class _ManageKdsScreensScreenState extends State<ManageKdsScreensScreen> {
  bool _isLoading = true;
  String _errorMessage = '';
  List<KdsScreenModel> _kdsScreens = [];

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ManageKdsScreensScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'manage_kds_screens_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchKdsScreens();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ManageKdsScreensScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'manage_kds_screens_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchKdsScreens();
        });
      }
    });

    _fetchKdsScreens();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> _fetchKdsScreens() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });
    try {
      final screens = await KdsManagementService.fetchKdsScreens(widget.token, widget.businessId);
      if (mounted) {
        setState(() {
          _kdsScreens = screens;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        setState(() {
          _errorMessage = l10n.manageKdsErrorLoading(e.toString().replaceFirst("Exception: ", ""));
          _isLoading = false;
        });
      }
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

  Future<void> _showAddEditKdsDialog({KdsScreenModel? kdsScreen}) async {
    final l10n = AppLocalizations.of(context)!;
    final TextEditingController nameController = TextEditingController(text: kdsScreen?.name ?? '');
    final TextEditingController descriptionController = TextEditingController(text: kdsScreen?.description ?? '');
    bool isActive = kdsScreen?.isActive ?? true;
    final formKey = GlobalKey<FormState>();
    bool isDialogSubmitting = false;
    String dialogErrorMessage = '';

    // *** DEĞİŞİKLİK BURADA: Artık `UserSession.limitsNotifier`'dan gelen anlık veriyi kullanıyoruz. ***
    final currentLimits = UserSession.limitsNotifier.value;
    if (kdsScreen == null && _kdsScreens.length >= currentLimits.maxKdsScreens) {
      _showLimitReachedDialog(
        l10n.manageKdsErrorLimitExceeded(currentLimits.maxKdsScreens.toString())
      );
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: !isDialogSubmitting,
      builder: (dialogContext) {
        final dialogL10n = AppLocalizations.of(dialogContext)!;
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.white.withOpacity(0.95),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(kdsScreen == null ? dialogL10n.manageKdsAddDialogTitle : dialogL10n.manageKdsEditDialogTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
            content: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: dialogL10n.manageKdsNameLabel,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.desktop_windows_outlined),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? dialogL10n.manageKdsNameValidator : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: descriptionController,
                      decoration: InputDecoration(
                        labelText: dialogL10n.manageKdsDescriptionLabel,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.description_outlined),
                      ),
                      maxLines: 2,
                    ),
                    SwitchListTile(
                      title: Text(dialogL10n.manageKdsIsActiveLabel),
                      value: isActive,
                      onChanged: (val) => setDialogState(() => isActive = val),
                      activeColor: Theme.of(context).primaryColorDark,
                      contentPadding: EdgeInsets.zero,
                    ),
                    if (dialogErrorMessage.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(dialogErrorMessage, style: const TextStyle(color: Colors.redAccent)),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isDialogSubmitting ? null : () => Navigator.pop(dialogContext, false),
                child: Text(dialogL10n.dialogButtonCancel),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).primaryColor),
                onPressed: isDialogSubmitting ? null : () async {
                  if (formKey.currentState!.validate()) {
                    setDialogState(() {
                      isDialogSubmitting = true;
                      dialogErrorMessage = '';
                    });
                    try {
                      if (kdsScreen == null) {
                        await KdsManagementService.createKdsScreen(
                          widget.token,
                          widget.businessId,
                          nameController.text.trim(),
                          descriptionController.text.trim(),
                          isActive,
                        );
                      } else {
                        await KdsManagementService.updateKdsScreen(
                          widget.token,
                          kdsScreen.id,
                          widget.businessId,
                          nameController.text.trim(),
                          descriptionController.text.trim(),
                          isActive,
                        );
                      }
                      if (mounted) Navigator.pop(dialogContext, true);
                    } catch (e) {
                      if (mounted) {
                        String rawError = e.toString().replaceFirst("Exception: ", "");
                        final jsonStartIndex = rawError.indexOf('{');
                        if (jsonStartIndex != -1) {
                          try {
                            final jsonString = rawError.substring(jsonStartIndex);
                            final decodedError = jsonDecode(jsonString);
                            if (decodedError is Map && decodedError['code'] == 'limit_reached') {
                              Navigator.of(dialogContext).pop(); // Mevcut dialogu kapat
                              _showLimitReachedDialog(decodedError['detail']);
                              dialogErrorMessage = '';
                            } else {
                              dialogErrorMessage = decodedError['detail'] ?? rawError;
                            }
                          } catch (_) {
                            dialogErrorMessage = rawError;
                          }
                        } else {
                          dialogErrorMessage = rawError;
                        }
                        setDialogState(() {});
                      }
                    } finally {
                      if (mounted) setDialogState(() => isDialogSubmitting = false);
                    }
                  }
                },
                child: isDialogSubmitting ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth:2, color: Colors.white)) : Text(kdsScreen == null ? dialogL10n.createButton : dialogL10n.updateButton, style: const TextStyle(color: Colors.white)),
              ),
            ],
          );
        });
      },
    );

    if (result == true && mounted) {
      _fetchKdsScreens();
    }
  }

  Future<void> _deleteKdsScreen(KdsScreenModel kdsScreen) async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AdminConfirmationDialog(
        title: l10n.manageKdsDeleteDialogTitle,
        content: l10n.manageKdsDeleteDialogContent(kdsScreen.name),
        confirmButtonText: l10n.dialogButtonDeleteConfirm,
        isDestructive: true,
      ),
    );

    if (confirm == true && mounted) {
      setState(() => _isLoading = true);
      try {
        await KdsManagementService.deleteKdsScreen(widget.token, kdsScreen.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.manageKdsSuccessDelete(kdsScreen.name)), backgroundColor: Colors.orangeAccent),
          );
          _fetchKdsScreens();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.manageKdsErrorDelete(e.toString().replaceFirst("Exception: ", ""))), backgroundColor: Colors.redAccent),
          );
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.manageKdsScreenTitle, style: const TextStyle(color: Colors.white)),
        centerTitle: true,
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
          ValueListenableBuilder<SubscriptionLimits>(
            valueListenable: UserSession.limitsNotifier,
            builder: (context, limits, child) {
              final canAddMore = _kdsScreens.length < limits.maxKdsScreens;
              return IconButton(
                icon: const Icon(Icons.add_circle_outline, color: Colors.white),
                tooltip: l10n.manageKdsTooltipAdd,
                onPressed: (_isLoading || !canAddMore) ? null : () => _showAddEditKdsDialog(),
              );
            },
          ),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
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
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _errorMessage.isNotEmpty
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(_errorMessage, style: const TextStyle(color: Colors.orangeAccent, fontSize: 16), textAlign: TextAlign.center),
                  ))
                : _kdsScreens.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.desktop_access_disabled_outlined, size: 70, color: Colors.white.withOpacity(0.5)),
                            const SizedBox(height: 16),
                            Text(
                              l10n.manageKdsNoScreensFound,
                              style: const TextStyle(color: Colors.white70, fontSize: 17),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white.withOpacity(0.8),
                                foregroundColor: Colors.blueGrey.shade900,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              ),
                              icon: const Icon(Icons.add),
                              label: Text(l10n.manageKdsCreateFirstButton),
                              onPressed: () => _showAddEditKdsDialog(),
                            )
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchKdsScreens,
                        color: Colors.white,
                        backgroundColor: Colors.blueGrey.shade700,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(8.0),
                          itemCount: _kdsScreens.length,
                          itemBuilder: (context, index) {
                            final kds = _kdsScreens[index];
                            return Card(
                              color: kds.isActive ? Colors.white.withOpacity(0.85) : Colors.grey.shade400.withOpacity(0.7),
                              margin: const EdgeInsets.symmetric(vertical: 6.0),
                              elevation: 3,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10.0),
                                side: BorderSide(color: kds.isActive ? Colors.teal.shade300 : Colors.grey.shade600, width: 1)
                              ),
                              child: ListTile(
                                leading: Icon(
                                  kds.isActive ? Icons.desktop_windows_rounded : Icons.desktop_access_disabled,
                                  color: kds.isActive ? Colors.teal.shade700 : Colors.black54,
                                  size: 30,
                                ),
                                title: Text(kds.name, style: TextStyle(fontWeight: FontWeight.bold, color: kds.isActive ? Colors.black87 : Colors.black54)),
                                subtitle: Text(
                                  l10n.manageKdsListItemSubtitle(
                                    kds.description ?? l10n.manageKdsNoDescription,
                                    kds.slug,
                                    kds.isActive ? l10n.generalYes : l10n.generalNo,
                                  ),
                                  style: TextStyle(fontSize: 12, color: kds.isActive ? Colors.black54 : Colors.black38),
                                ),
                                isThreeLine: true,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(Icons.edit_outlined, color: Colors.blueAccent.shade200),
                                      tooltip: l10n.tooltipEdit,
                                      onPressed: () => _showAddEditKdsDialog(kdsScreen: kds),
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.delete_forever_outlined, color: Colors.redAccent.shade200),
                                      tooltip: l10n.tooltipDelete,
                                      onPressed: () => _deleteKdsScreen(kds),
                                    ),
                                  ],
                                ),
                                onTap: () => _showAddEditKdsDialog(kdsScreen: kds),
                              ),
                            );
                          },
                        ),
                      ),
      ),
    );
  }
}