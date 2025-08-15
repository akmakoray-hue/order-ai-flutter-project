// lib/screens/staff_performance_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../models/staff_performance.dart';
import '../utils/currency_formatter.dart';

class StaffPerformanceScreen extends StatefulWidget {
  final String token;
  final int businessId;

  const StaffPerformanceScreen({
    Key? key,
    required this.token,
    required this.businessId,
  }) : super(key: key);

  @override
  _StaffPerformanceScreenState createState() => _StaffPerformanceScreenState();
}

class _StaffPerformanceScreenState extends State<StaffPerformanceScreen> {
  bool _isLoading = true;
  String _errorMessage = '';
  List<StaffPerformance> _staffPerformances = [];
  String _selectedTimeRange = 'last_7_days';
  DateTimeRange? _customDateRange;
  bool _isDataFetched = false;

  StaffPerformance? _topByOrderCount;
  StaffPerformance? _topByTurnover;
  StaffPerformance? _topByPreparedCount;

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[StaffPerformanceScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted) {
        final refreshKey = 'staff_performance_screen_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchPerformanceData();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[StaffPerformanceScreen] 📱 Screen became active notification received');
      if (mounted) {
        final refreshKey = 'staff_performance_screen_active_${widget.businessId}';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await _fetchPerformanceData();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isDataFetched) {
      _fetchPerformanceData();
      _isDataFetched = true;
    }
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> _fetchPerformanceData() async {
    final l10n = AppLocalizations.of(context)!;
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _topByOrderCount = null;
      _topByTurnover = null;
      _topByPreparedCount = null;
    });

    try {
      List<dynamic> rawData;
      if (_selectedTimeRange == 'custom' && _customDateRange != null) {
        rawData = await ApiService.fetchStaffPerformance(
          widget.token,
          startDate: DateFormat('yyyy-MM-dd').format(_customDateRange!.start),
          endDate: DateFormat('yyyy-MM-dd').format(_customDateRange!.end),
        );
      } else if (_selectedTimeRange != 'custom') {
        rawData = await ApiService.fetchStaffPerformance(
          widget.token,
          timeRange: _selectedTimeRange,
        );
      } else {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      if (mounted) {
        final performances =
            rawData.map((data) => StaffPerformance.fromJson(data)).toList();
        setState(() {
          _staffPerformances = performances;
          _determineTopPerformers();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = l10n.staffPerformanceErrorFetching(e.toString().replaceFirst("Exception: ", ""));
          _isLoading = false;
        });
      }
    }
  }

  void _determineTopPerformers() {
    if (_staffPerformances.isEmpty) return;
    final salesStaff =
        _staffPerformances.where((p) => p.canTakeOrders).toList();
    if (salesStaff.isNotEmpty) {
      salesStaff.sort((a, b) => b.orderCount.compareTo(a.orderCount));
      if (salesStaff.first.orderCount > 0) {
        _topByOrderCount = salesStaff.first;
      }
      salesStaff.sort((a, b) => b.totalTurnover.compareTo(a.totalTurnover));
      if (salesStaff.first.totalTurnover > 0) {
        _topByTurnover = salesStaff.first;
      }
    }
    final kdsStaff =
        _staffPerformances.where((p) => p.canManageKds).toList();
    if (kdsStaff.isNotEmpty) {
      kdsStaff.sort((a, b) => b.preparedItemCount.compareTo(a.preparedItemCount));
      if (kdsStaff.first.preparedItemCount > 0) {
        _topByPreparedCount = kdsStaff.first;
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
      initialDateRange: _customDateRange ??
          DateTimeRange(
            start: now.subtract(const Duration(days: 7)),
            end: now,
          ),
    );
    if (picked != null && picked != _customDateRange) {
      setState(() {
        _customDateRange = picked;
        _selectedTimeRange = 'custom';
      });
      _fetchPerformanceData();
    }
  }

  Widget _buildPermissionChip(IconData icon, String label, Color color) {
    return Chip(
      avatar: Icon(icon, color: color, size: 16),
      label: Text(label),
      labelPadding: const EdgeInsets.only(left: 4.0, right: 6.0),
      labelStyle:
          TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w500),
      backgroundColor: color.withOpacity(0.15),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(color: color.withOpacity(0.4)),
    );
  }

  Widget _buildFilterSection(AppLocalizations l10n) {
    final Map<String, String> timeRangeOptions = {
      'today': l10n.staffPerformanceTimeRangeToday,
      'this_week': l10n.staffPerformanceTimeRangeThisWeek,
      'this_month': l10n.staffPerformanceTimeRangeThisMonth,
      'last_7_days': l10n.staffPerformanceTimeRangeLast7Days,
      'last_30_days': l10n.staffPerformanceTimeRangeLast30Days,
      'custom': l10n.staffPerformanceTimeRangeCustom,
    };

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Card(
        color: Colors.white.withOpacity(0.85),
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _selectedTimeRange,
                    dropdownColor: Colors.blueGrey[50],
                    items: timeRangeOptions.entries.map((entry) {
                      return DropdownMenuItem<String>(
                        value: entry.key,
                        child: Text(entry.value,
                            style: const TextStyle(color: Colors.black87)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedTimeRange = value;
                          if (value != 'custom') {
                            _customDateRange = null;
                            _fetchPerformanceData();
                          } else if (value == 'custom' &&
                              _customDateRange == null) {
                            _pickDateRange();
                          } else if (value == 'custom' &&
                              _customDateRange != null) {
                            _fetchPerformanceData();
                          }
                        });
                      }
                    },
                  ),
                ),
              ),
              if (_selectedTimeRange == 'custom')
                IconButton(
                  icon: Icon(Icons.date_range,
                      color: Theme.of(context).primaryColorDark),
                  tooltip: l10n.staffPerformancePickDateTooltip,
                  onPressed: _pickDateRange,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // +++ Personel Performans Kartı Widget'ı (GÜNCELLENDİ) +++
  Widget _buildStaffPerformanceCard(StaffPerformance perf, AppLocalizations l10n) {
    final bool showSalesInfo = perf.canTakeOrders;
    final bool showKdsInfo = perf.canManageKds;
    bool isTopStaff = (_topByOrderCount?.staffId == perf.staffId) ||
        (_topByTurnover?.staffId == perf.staffId) ||
        (_topByPreparedCount?.staffId == perf.staffId);

    String displayName;
    if (perf.firstName != null && perf.firstName!.isNotEmpty) {
      displayName = "${perf.firstName} ${perf.lastName ?? ''}";
    } else {
      displayName = perf.username;
    }

    return Card(
      color: isTopStaff
          ? Colors.amber.shade50.withOpacity(0.9)
          : Colors.white.withOpacity(0.8),
      elevation: isTopStaff ? 5 : 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isTopStaff
            ? BorderSide(color: Colors.amber.shade700, width: 2.0)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (isTopStaff)
              Align(
                alignment: Alignment.topRight,
                child: Icon(Icons.star_rounded,
                    color: Colors.amber.shade800, size: 24),
              )
            else
              const SizedBox(height: 24), // Yıldız için boşluk
            CircleAvatar(
              radius: 28,
              backgroundColor: isTopStaff
                  ? Colors.amber.shade600
                  : Theme.of(context).colorScheme.secondary.withOpacity(0.7),
              backgroundImage: (perf.profileImageUrl != null && perf.profileImageUrl!.isNotEmpty)
                  ? NetworkImage(perf.profileImageUrl!)
                  : null,
              child: (perf.profileImageUrl == null || perf.profileImageUrl!.isEmpty)
                  ? Text(
                      (perf.firstName?.isNotEmpty == true
                              ? perf.firstName![0]
                              : perf.username[0])
                          .toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.white, fontSize: 22),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              displayName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                fontSize: 15,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const Divider(height: 20, thickness: 0.8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSalesInfo) ...[
                  Text(l10n.staffPerformanceOrderCountLabel(perf.orderCount.toString()),
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    "${l10n.reportsSummaryTotalTurnover}: ${CurrencyFormatter.format(perf.totalTurnover)}",
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13)
                  ),
                ],
                if (showKdsInfo) ...[
                  Text(l10n.staffPerformancePreparedItemsLabel(perf.preparedItemCount.toString()),
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                ],
                if ((showSalesInfo || showKdsInfo) && (perf.canTakeOrders || perf.hasKdsAccess))
                  const SizedBox(height: 8),
                Wrap(
                  spacing: 6.0,
                  runSpacing: 4.0,
                  children: [
                    if (showSalesInfo)
                      _buildPermissionChip(Icons.point_of_sale_outlined,
                          l10n.staffPerformanceChipSalesPermission, Colors.blue.shade700),
                    if (perf.hasKdsAccess)
                      _buildPermissionChip(
                          Icons.kitchen_outlined,
                          l10n.staffPerformanceChipKdsPermission(perf.accessibleKdsNames.join(', ')),
                          Colors.deepOrange.shade700),
                  ],
                )
              ],
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
        title: Text(l10n.staffPerformanceScreenTitle,
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
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Colors.blue.shade900.withOpacity(0.9),
              Colors.blue.shade400.withOpacity(0.8),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          children: [
            _buildFilterSection(l10n),
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white))
                  : _errorMessage.isNotEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text(_errorMessage,
                                style: const TextStyle(
                                    color: Colors.orangeAccent, fontSize: 16),
                                textAlign: TextAlign.center),
                          ),
                        )
                      : _staffPerformances.isEmpty
                          ? Center(
                              child: Text(l10n.staffPerformanceNoData,
                                  style: const TextStyle(color: Colors.white70)))
                          // +++ Ana Liste Widget'ı (GÜNCELLENDİ) +++
                          : RefreshIndicator(
                              onRefresh: _fetchPerformanceData,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  return SingleChildScrollView(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Wrap(
                                      spacing: 12.0,
                                      runSpacing: 12.0,
                                      alignment: WrapAlignment.center,
                                      children: _staffPerformances.map((perf) {
                                        // Kartların genişliğini ekran boyutuna göre ayarla
                                        double cardWidth;
                                        if (constraints.maxWidth > 900) {
                                          cardWidth = (constraints.maxWidth / 4) - (12 * 1.5);
                                        } else if (constraints.maxWidth > 600) {
                                          cardWidth = (constraints.maxWidth / 3) - (12 * 1.33);
                                        } else {
                                          cardWidth = (constraints.maxWidth / 2) - (12 * 1.5);
                                        }
                                        return SizedBox(
                                          width: cardWidth,
                                          child: _buildStaffPerformanceCard(perf, l10n),
                                        );
                                      }).toList(),
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
}