// lib/screens/schedule_management_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:collection/collection.dart'; // firstWhereOrNull için
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/schedule_service.dart';
import '../services/api_service.dart';
import '../models/shift_model.dart';
import '../models/scheduled_shift_model.dart';
import 'manage_shifts_screen.dart';
import '../widgets/schedule/multi_day_shift_dialog.dart';
import '../services/user_session.dart';

class ScheduleManagementScreen extends StatefulWidget {
  final String token;
  final int businessId;
  final int? preSelectedStaffId;
  final bool isFromSetupWizard;

  const ScheduleManagementScreen({
    Key? key,
    required this.token,
    required this.businessId,
    this.preSelectedStaffId,
    this.isFromSetupWizard = false,
  }) : super(key: key);

  @override
  _ScheduleManagementScreenState createState() =>
      _ScheduleManagementScreenState();
}

class _ScheduleManagementScreenState extends State<ScheduleManagementScreen> {
  bool _isLoading = true;
  String _errorMessage = '';

  List<dynamic> _staffList = [];
  List<Shift> _shiftTemplates = [];
  Map<DateTime, List<ScheduledShift>> _events = {};

  DateTime _focusedDay = DateTime.now();

  bool _isMultiSelectMode = false;
  List<DateTime> _multiSelectedDays = [];
  DateTime? _selectedDay;

  bool _shiftWasAssigned = false;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ScheduleManagementScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'schedule_management_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchInitialData();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ScheduleManagementScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'schedule_management_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchInitialData();
        });
      }
    });

    _fetchInitialData();
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        ApiService.getStaffList(widget.token),
        ScheduleService.fetchShifts(widget.token),
      ]);

      if (mounted) {
        setState(() {
          _staffList = results[0];
          _shiftTemplates = results[1] as List<Shift>;
        });
        await _fetchEventsForMonth(_focusedDay);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = AppLocalizations.of(context)!.scheduleErrorLoadingData(e.toString().replaceFirst("Exception: ", ""));
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchEventsForMonth(DateTime month) async {
    if (!mounted) return;
    setState(() {
      _errorMessage = '';
    });
    try {
      final firstDay = DateTime(month.year, month.month, 1);
      final lastDay = DateTime(month.year, month.month + 1, 0);
      final fetchedEvents = await ScheduleService.fetchScheduledShifts(
          widget.token, firstDay, lastDay);
      if (mounted) {
        _events.clear();
        for (var event in fetchedEvents) {
          final day =
              DateTime.utc(event.date.year, event.date.month, event.date.day);
          if (_events[day] == null) {
            _events[day] = [];
          }
          _events[day]!.add(event);
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = AppLocalizations.of(context)!.scheduleErrorFetchingShifts(e.toString().replaceFirst("Exception: ", ""));
          _isLoading = false;
        });
      }
    }
  }

  List<ScheduledShift> _getEventsForDay(DateTime day) {
    return _events[DateTime.utc(day.year, day.month, day.day)] ?? [];
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (_isMultiSelectMode) {
      setState(() {
        _focusedDay = focusedDay;
        final dayUtc =
            DateTime.utc(selectedDay.year, selectedDay.month, selectedDay.day);
        if (_multiSelectedDays.contains(dayUtc)) {
          _multiSelectedDays.remove(dayUtc);
        } else {
          _multiSelectedDays.add(dayUtc);
        }
      });
    } else {
      if (!isSameDay(_selectedDay, selectedDay)) {
        setState(() {
          _selectedDay = selectedDay;
          _focusedDay = focusedDay;
        });
      }
    }
  }

  void _toggleMultiSelectMode() {
    setState(() {
      _isMultiSelectMode = !_isMultiSelectMode;
      _multiSelectedDays.clear();
      if (!_isMultiSelectMode) {
        _selectedDay = _focusedDay;
      } else {
        _selectedDay = null;
      }
    });
  }

  dynamic _getStaffMemberById(int staffId) {
    return _staffList.firstWhereOrNull((staff) => staff['id'] == staffId);
  }

  Future<void> _showShiftAssignmentDialog() async {
    if (_selectedDay == null) return;
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();

    if (_shiftTemplates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.scheduleErrorCreateShiftTemplateFirst),
          backgroundColor: Colors.orangeAccent,
        ),
      );
      return;
    }

    Map<int, int?> selectedShiftsForStaff = {};

    showDialog(
      context: context,
      builder: (ctx) {
        final dialogL10n = AppLocalizations.of(ctx)!;
        final formattedDate = DateFormat('d MMMM EEEE', locale).format(_selectedDay!);
        
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(
              dialogL10n.scheduleTitleAssignShiftForDate(formattedDate),
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: _staffList.isEmpty
                  ? Center(
                      child: Text(dialogL10n.scheduleErrorNoStaffToAssign,
                          style: const TextStyle(color: Colors.blueGrey)))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _staffList.length,
                      itemBuilder: (context, index) {
                        final staff = _staffList[index];
                        final existingAssignment =
                            _getEventsForDay(_selectedDay!).firstWhere(
                          (s) => s.staffId == staff['id'],
                          orElse: () => ScheduledShift(
                              id: 0,
                              staffId: 0,
                              staffUsername: '',
                              date: DateTime.now(),
                              shift: Shift(
                                  id: 0,
                                  name: '',
                                  startTime: TimeOfDay.now(),
                                  endTime: TimeOfDay.now(),
                                  color: Colors.transparent)),
                        );

                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(vertical: 4.0),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8.0)),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundImage: (staff['profile_image_url'] !=
                                          null &&
                                      staff['profile_image_url']!.isNotEmpty)
                                  ? NetworkImage(staff['profile_image_url']!)
                                      as ImageProvider
                                  : null,
                              backgroundColor: Colors.grey.shade300,
                              child: (staff['profile_image_url'] == null ||
                                      staff['profile_image_url']!.isEmpty)
                                  ? Text(
                                      (staff['first_name'] != null &&
                                              staff['first_name'].isNotEmpty
                                          ? staff['first_name'][0]
                                          : staff['username'][0])
                                      .toUpperCase(),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white),
                                    )
                                  : null,
                            ),
                            title: Text(
                              staff['first_name'] != null &&
                                      staff['first_name'].isNotEmpty
                                  ? "${staff['first_name']} ${staff['last_name'] ?? ''}"
                                  : staff['username'],
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueGrey),
                            ),
                            subtitle: existingAssignment.id != 0
                                ? Text(
                                    existingAssignment.shift.name,
                                    style: TextStyle(
                                        color: existingAssignment.shift.color,
                                        fontWeight: FontWeight.bold),
                                  )
                                : Text(dialogL10n.scheduleStatusNoShiftAssigned,
                                    style: const TextStyle(
                                        fontStyle: FontStyle.italic,
                                        color: Colors.grey)),
                            trailing: existingAssignment.id != 0
                                ? IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.redAccent),
                                    tooltip: dialogL10n.scheduleTooltipRemoveShift,
                                    onPressed: () async {
                                      await ScheduleService.deleteScheduledShift(
                                          widget.token, existingAssignment.id);
                                      await _fetchEventsForMonth(_focusedDay);
                                      if (mounted) setDialogState(() {});
                                    })
                                : DropdownButton<int>(
                                    value: selectedShiftsForStaff[staff['id']],
                                    hint: Text(dialogL10n.scheduleHintSelect,
                                        style:
                                            const TextStyle(color: Colors.blueGrey)),
                                    items: _shiftTemplates
                                        .map((shift) => DropdownMenuItem<int>(
                                              value: shift.id,
                                              child: Text(shift.name),
                                            ))
                                        .toList(),
                                    onChanged: (shiftId) async {
                                      if (shiftId != null) {
                                        setDialogState(() =>
                                            selectedShiftsForStaff[staff['id']] =
                                                shiftId);
                                        await ScheduleService.assignShiftToStaff(
                                            widget.token,
                                            staffId: staff['id'],
                                            shiftId: shiftId,
                                            date: _selectedDay!);
                                        if (widget.isFromSetupWizard) {
                                          _shiftWasAssigned = true;
                                        }
                                        await _fetchEventsForMonth(_focusedDay);
                                        if (mounted) setDialogState(() {});
                                      }
                                    },
                                  ),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.blueGrey),
                onPressed: () => Navigator.pop(ctx),
                child: Text(dialogL10n.dialogButtonClose),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _showMultiDayShiftAssignmentDialog() async {
    final l10n = AppLocalizations.of(context)!;
    if (_multiSelectedDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.scheduleErrorSelectAtLeastOneDay)),
      );
      return;
    }
    if (_shiftTemplates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(l10n.scheduleErrorCreateShiftTemplateFirst),
            backgroundColor: Colors.orangeAccent),
      );
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => MultiDayShiftDialog(
        selectedDates: _multiSelectedDays,
        staffList: _staffList,
        shiftTemplates: _shiftTemplates,
        onConfirm: (staffIds, shiftId) async {
          try {
            await ScheduleService.assignShiftToMultiple(
              token: widget.token,
              staffIds: staffIds,
              dates: _multiSelectedDays,
              shiftId: shiftId,
            );
            if (widget.isFromSetupWizard) {
              _shiftWasAssigned = true;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content:
                      Text(l10n.scheduleSuccessMultiDayAssignment(_multiSelectedDays.length)),
                  backgroundColor: Colors.green),
            );
            await _fetchEventsForMonth(_focusedDay);
            setState(() {
              _multiSelectedDays.clear();
            });
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text(l10n.scheduleErrorMultiDayAssignment(e.toString())),
                  backgroundColor: Colors.red),
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();

    return WillPopScope(
      onWillPop: () async {
        if (widget.isFromSetupWizard) {
          Navigator.pop(context, _shiftWasAssigned);
          return false;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.scheduleTitle,
              style:
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () {
              if (widget.isFromSetupWizard) {
                Navigator.pop(context, _shiftWasAssigned);
              } else {
                Navigator.pop(context);
              }
            },
          ),
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF283593), Color(0xFF455A64)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor:
                    _isMultiSelectMode ? Colors.white.withOpacity(0.3) : Colors.transparent,
              ),
              icon: Icon(
                  _isMultiSelectMode
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 20),
              label: Text(l10n.scheduleButtonMultiSelect),
              onPressed: _toggleMultiSelectMode,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined, color: Colors.white),
              tooltip: l10n.scheduleTooltipManageShiftTemplates,
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ManageShiftsScreen()),
                );
                await _fetchInitialData();
              },
            ),
          ],
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.blue, Colors.lightBlueAccent],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: _isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _errorMessage.isNotEmpty
                  ? Center(
                      child: Text(_errorMessage,
                          style: const TextStyle(color: Colors.red)))
                  // === HATA DÜZELTMESİ: Column widget'ı SingleChildScrollView ile sarıldı ===
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          if (widget.isFromSetupWizard)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              color: Colors.amber.shade700.withOpacity(0.9),
                              child: Text(
                                l10n.scheduleSetupWizardPrompt,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                          Card(
                            margin: const EdgeInsets.all(16.0),
                            elevation: 4,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15.0)),
                            child: TableCalendar<ScheduledShift>(
                              locale: locale,
                              firstDay: DateTime.utc(2020, 1, 1),
                              lastDay: DateTime.utc(2030, 12, 31),
                              focusedDay: _focusedDay,
                              selectedDayPredicate: (day) {
                                if (_isMultiSelectMode) {
                                  return _multiSelectedDays.contains(DateTime.utc(
                                      day.year, day.month, day.day));
                                }
                                return isSameDay(_selectedDay, day);
                              },
                              onDaySelected: _onDaySelected,
                              onPageChanged: (focusedDay) {
                                _focusedDay = focusedDay;
                                _fetchEventsForMonth(focusedDay);
                              },
                              eventLoader: _getEventsForDay,
                              calendarBuilders: CalendarBuilders(
                                markerBuilder: (context, date, events) {
                                  if (events.isNotEmpty) {
                                    return Positioned(
                                      right: 1,
                                      bottom: 1,
                                      child: _buildEventsMarker(events),
                                    );
                                  }
                                  return null;
                                },
                              ),
                              headerStyle: HeaderStyle(
                                formatButtonVisible: false,
                                titleTextStyle: const TextStyle(
                                    color: Colors.blueGrey,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18.0),
                                leftChevronIcon: const Icon(Icons.chevron_left,
                                    color: Colors.blueGrey),
                                rightChevronIcon: const Icon(Icons.chevron_right,
                                    color: Colors.blueGrey),
                              ),
                              calendarStyle: CalendarStyle(
                                selectedDecoration: BoxDecoration(
                                  color: _isMultiSelectMode
                                      ? Colors.green.shade400
                                      : Colors.blue,
                                  shape: BoxShape.circle,
                                ),
                                todayDecoration: BoxDecoration(
                                  color: Colors.lightBlueAccent.withOpacity(0.5),
                                  shape: BoxShape.circle,
                                ),
                                markerDecoration: BoxDecoration(
                                  color: Colors.blueAccent.withOpacity(0.7),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8.0),
                          // Expanded kaldırıldı, çünkü artık SingleChildScrollView içindeyiz
                          _buildEventList(),
                        ],
                      ),
                    ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _isLoading ||
                  (_isMultiSelectMode
                      ? _multiSelectedDays.isEmpty
                      : _selectedDay == null)
              ? null
              : (_isMultiSelectMode
                  ? _showMultiDayShiftAssignmentDialog
                  : _showShiftAssignmentDialog),
          label: Text(
              _isMultiSelectMode ? l10n.scheduleFabManageSelectedDays : l10n.scheduleFabManageDay,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          icon: Icon(
              _isMultiSelectMode ? Icons.date_range : Icons.edit_calendar,
              color: Colors.white),
          backgroundColor:
              _isMultiSelectMode && _multiSelectedDays.isEmpty
                  ? Colors.grey
                  : Colors.blue,
          tooltip: _isMultiSelectMode
              ? l10n.scheduleTooltipAssignToSelectedDays
              : l10n.scheduleTooltipAssignRemoveForDay,
        ),
      ),
    );
  }

  Widget _buildEventsMarker(List<ScheduledShift> events) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.blue.shade400,
      ),
      child: Center(
        child: Text('${events.length}',
            style: const TextStyle(color: Colors.white, fontSize: 10)),
      ),
    );
  }

  Widget _buildEventList() {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).toString();
    final DateTime dayToDisplay =
        _isMultiSelectMode ? _focusedDay : (_selectedDay ?? _focusedDay);
    final selectedDayEvents = _getEventsForDay(dayToDisplay);

    if (selectedDayEvents.isEmpty) {
      final formattedDate = DateFormat('d MMMM', locale).format(dayToDisplay);
      return Center(
        child: Text(
          l10n.scheduleNoShiftsForDate(formattedDate),
          style: const TextStyle(
              color: Colors.white70, fontWeight: FontWeight.bold),
        ),
      );
    }
    return GridView.builder(
      // === HATA DÜZELTMESİ: Bu özellikler eklendi ===
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      // ===========================================
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 350, // Her bir kartın maksimum genişliği
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 2.5, // Kartların en/boy oranı
      ),
      itemCount: selectedDayEvents.length,
      itemBuilder: (context, index) {
        final event = selectedDayEvents[index];
        final staffMember = _getStaffMemberById(event.staffId);
        final staffFullName = staffMember != null
            ? (staffMember['first_name'] != null &&
                    staffMember['first_name'].isNotEmpty
                ? "${staffMember['first_name']} ${staffMember['last_name'] ?? ''}"
                : staffMember['username'])
            : event.staffUsername;
        final staffImageUrl = staffMember?['profile_image_url'];

        return Card(
          elevation: 2,
          margin: EdgeInsets.zero,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10.0)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundImage: (staffImageUrl != null && staffImageUrl.isNotEmpty)
                  ? NetworkImage(staffImageUrl!) as ImageProvider
                  : null,
              backgroundColor: Colors.grey.shade300,
              child: (staffImageUrl == null || staffImageUrl.isEmpty)
                  ? Text(
                      (staffFullName.isNotEmpty ? staffFullName[0] : '?')
                          .toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    )
                  : null,
            ),
            title: Text('$staffFullName - ${event.shift.name}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.blueGrey)),
            subtitle: Text(
                '${event.shift.startTime.format(context)} - ${event.shift.endTime.format(context)}',
                style: const TextStyle(color: Colors.grey)),
            trailing: Icon(Icons.schedule_outlined, color: event.shift.color),
            onTap: _showShiftAssignmentDialog,
          ),
        );
      },
    );
  }
}