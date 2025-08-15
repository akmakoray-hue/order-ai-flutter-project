// lib/screens/reports_screen.dart

import '../services/notification_center.dart';
import '../services/refresh_manager.dart';
import 'dart:convert';
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency_formatter.dart';
import '../services/report_exporter_service.dart';

class ReportsScreen extends StatefulWidget {
  final String token;
  const ReportsScreen({Key? key, required this.token}) : super(key: key);

  @override
  _ReportsScreenState createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _isInit = true;
  bool isLoading = true;
  double totalTurnover = 0.0;
  int totalOrders = 0;
  Map<String, dynamic>? bestSellingItem;
  Map<String, dynamic>? leastSellingItem;
  String errorMessage = '';
  String selectedFilter = 'day';
  DateTimeRange? customDateRange;
  List<dynamic> chartData = [];
  String chartTitle = '';
  String activeChartType = 'daily';
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    
    // 🆕 NotificationCenter listener'ları ekle
    NotificationCenter.instance.addObserver('refresh_all_screens', (data) {
      debugPrint('[ReportsScreen] 📡 Global refresh received: ${data['event_type']}');
      if (mounted && !_isInit) {
        final refreshKey = 'reports_screen';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchReport();
        });
      }
    });

    NotificationCenter.instance.addObserver('screen_became_active', (data) {
      debugPrint('[ReportsScreen] 📱 Screen became active notification received');
      if (mounted && !_isInit) {
        final refreshKey = 'reports_screen_active';
        RefreshManager.throttledRefresh(refreshKey, () async {
          await fetchReport();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isInit) {
      final l10n = AppLocalizations.of(context)!;
      chartTitle = l10n.reportsChartTitleNoData;
      fetchReport();
      _isInit = false;
    }
  }

  @override
  void dispose() {
    // NotificationCenter listener'ları temizlenmeli ama anonymous function olduğu için
    // bu ekran için önemli değil çünkü genelde kısa süre açık kalır
    super.dispose();
  }

  Future<void> fetchReport() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
      errorMessage = '';
      chartData = [];
    });

    final l10n = AppLocalizations.of(context)!;
    final locale = l10n.localeName;

    try {
      Uri url;
      const String reportEndpoint = '/reports/general/';
      Map<String, String> queryParams = {};

      if (selectedFilter == 'custom') {
        if (customDateRange == null) {
          if (mounted) {
            setState(() {
              isLoading = false;
              errorMessage = l10n.reportsErrorSelectDateRange;
            });
          }
          return;
        }
        queryParams['start_date'] =
            DateFormat('yyyy-MM-dd').format(customDateRange!.start);
        queryParams['end_date'] =
            DateFormat('yyyy-MM-dd').format(customDateRange!.end);
      } else {
        queryParams['time_range'] = selectedFilter;
      }
      url = ApiService.getUrl(reportEndpoint)
          .replace(queryParameters: queryParams);

      final response = await http.get(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer ${widget.token}"
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        setState(() {
          totalTurnover =
              double.tryParse(data['total_turnover']?.toString() ?? '0.0') ??
                  0.0;
          totalOrders = data['total_orders'] as int? ?? 0;
          bestSellingItem = data['best_selling_item'] as Map<String, dynamic>?;
          leastSellingItem =
              data['least_selling_item'] as Map<String, dynamic>?;

          String backendEffectiveTimeRange =
              data['time_range_selected'] ?? 'day';

          if (backendEffectiveTimeRange == 'day' &&
              data['daily_turnover_for_chart'] != null) {
            chartData = data['daily_turnover_for_chart'] as List<dynamic>? ?? [];
            chartTitle = l10n.reportsChartTitleHourly(DateFormat('dd MMM', locale)
                .format(customDateRange?.start ?? DateTime.now()));
            activeChartType = 'daily';
          } else if (backendEffectiveTimeRange == 'week' &&
              data['weekly_turnover_for_chart'] != null) {
            chartData = data['weekly_turnover_for_chart'] as List<dynamic>? ?? [];
            if (customDateRange != null) {
              chartTitle = l10n.reportsChartTitleDailyRange(
                  DateFormat('dd MMM', locale).format(customDateRange!.start),
                  DateFormat('dd MMM', locale).format(customDateRange!.end));
            } else {
              chartTitle = l10n.reportsChartTitleDailyThisWeek;
            }
            activeChartType = 'weekly';
          } else if (data['monthly_turnover_for_chart'] != null &&
              (data['monthly_turnover_for_chart'] as List).isNotEmpty) {
            chartData =
                data['monthly_turnover_for_chart'] as List<dynamic>? ?? [];
            if (customDateRange != null) {
              chartTitle = l10n.reportsChartTitleMonthlyRange(
                  DateFormat('MMM yy', locale).format(customDateRange!.start),
                  DateFormat('MMM yy', locale).format(customDateRange!.end));
            } else if (selectedFilter == 'month') {
              chartTitle = l10n.reportsChartTitleMonthlyThisMonth(
                  DateFormat.MMMM(locale).format(DateTime.now()),
                  DateTime.now().year.toString());
            } else if (selectedFilter == 'year') {
              chartTitle = l10n
                  .reportsChartTitleMonthlyThisYear(DateTime.now().year.toString());
            } else {
              chartTitle = l10n.reportsChartTitleMonthlyDefault;
            }
            activeChartType = 'monthly';
          } else {
            chartData = [];
            chartTitle = l10n.reportsChartTitleNoData;
            activeChartType = 'none';
          }
          isLoading = false;
        });
      } else {
        setState(() {
          errorMessage =
              l10n.reportsErrorFetching(response.statusCode.toString());
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = l10n.errorGeneral(e.toString());
          isLoading = false;
        });
      }
    }
  }

  Future<void> _exportReport() async {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _isExporting = true);

    try {
      final List<dynamic> detailedData =
          await ApiService.fetchDetailedSalesReport(
        widget.token,
        timeRange: selectedFilter,
        startDate: customDateRange != null
            ? DateFormat('yyyy-MM-dd').format(customDateRange!.start)
            : null,
        endDate: customDateRange != null
            ? DateFormat('yyyy-MM-dd').format(customDateRange!.end)
            : null,
      );

      if (detailedData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(l10n.reportsErrorNoDataToExport),
                backgroundColor: Colors.orangeAccent),
          );
        }
        return;
      }

      final String fileName =
          "Satis_Raporu_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}";
      await ReportExporterService.createAndExportExcel(detailedData, fileName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(l10n.reportsErrorExportFailed(e.toString())),
              backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final l10n = AppLocalizations.of(context)!;

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: customDateRange ??
          DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
      locale: Locale(l10n.localeName),
    );
    if (picked != null) {
      setState(() {
        customDateRange = picked;
        selectedFilter = 'custom';
      });
      fetchReport();
    }
  }

  Widget _buildTurnoverChart() {
    final l10n = AppLocalizations.of(context)!;
    final locale = l10n.localeName;

    if (chartData.isEmpty) {
      return Center(
          child: Text(chartTitle,
              style: const TextStyle(color: Colors.white70, fontSize: 16)));
    }
    List<BarChartGroupData> barGroups = [];
    int index = 0;
    double maxY = 0;

    for (var item in chartData) {
      final turnover = (item['turnover'] as num?)?.toDouble() ?? 0.0;
      maxY = max(maxY, turnover);
    }
    if (maxY == 0 && chartData.isNotEmpty) {
      maxY = 100;
    } else if (maxY == 0 && chartData.isEmpty) {
      return const SizedBox.shrink();
    }

    for (var item in chartData) {
      final turnover = (item['turnover'] as num?)?.toDouble() ?? 0.0;
      barGroups.add(
        BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: turnover,
              gradient: LinearGradient(
                colors: [
                  Colors.blueAccent.shade100,
                  Colors.indigoAccent.shade100
                ],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
              ),
              width: 16,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4), topRight: Radius.circular(4)),
            ),
          ],
        ),
      );
      index++;
    }

    return AspectRatio(
      aspectRatio: 1.7,
      child: Card(
        color: Colors.white.withOpacity(0.8),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY * 1.2,
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (barChartGroupData) =>
                      Colors.blueGrey.shade700,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    String label = '';
                    if (activeChartType == 'daily' &&
                        group.x.toInt() < chartData.length) {
                      label = chartData[group.x.toInt()]['hour_str'] ?? '';
                    } else if (activeChartType == 'weekly' &&
                        group.x.toInt() < chartData.length) {
                      label = chartData[group.x.toInt()]['day_str'] ?? '';
                    } else if (activeChartType == 'monthly' &&
                        group.x.toInt() < chartData.length) {
                      label =
                          chartData[group.x.toInt()]['month_year_str'] ?? '';
                    }
                    return BarTooltipItem(
                      '$label\n',
                      const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                      children: <TextSpan>[
                        TextSpan(
                          text: CurrencyFormatter.format(rod.toY),
                          style: const TextStyle(
                            color: Colors.yellowAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              titlesData: FlTitlesData(
                show: true,
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) {
                      if (value == 0 && maxY > 0)
                        return const Text('0', style: TextStyle(fontSize: 10));
                      if (value == meta.max && maxY > 0)
                        return Text(NumberFormat.compact().format(meta.max),
                            style: const TextStyle(fontSize: 10));
                      if (value > 0 &&
                          value < meta.max &&
                          (maxY > 0 &&
                              (value % (meta.max / 4).ceilToDouble() < 1) ||
                              value % (meta.max / 3).ceilToDouble() < 1)) {
                        return Text(NumberFormat.compact().format(value),
                            style: const TextStyle(fontSize: 10));
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    getTitlesWidget: (value, meta) {
                      int idx = value.toInt();
                      if (idx < 0 || idx >= chartData.length)
                        return const SizedBox.shrink();
                      String title = '';
                      if (activeChartType == 'daily') {
                        title = chartData[idx]['hour_str'] ?? '';
                      } else if (activeChartType == 'weekly') {
                        try {
                          DateTime date =
                              DateTime.parse(chartData[idx]['day']);
                          title = DateFormat('d MMM', locale).format(date);
                        } catch (e) {
                          title = chartData[idx]['day_str'] ?? '';
                        }
                      } else if (activeChartType == 'monthly') {
                        try {
                          final date = DateFormat('yyyy-MM')
                              .parse(chartData[idx]['month_year_str']);
                          title = DateFormat.MMM(locale).format(date);
                        } catch (e) {
                          title = chartData[idx]['month_year_str'] ?? '';
                        }
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(title,
                            style: const TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w500)),
                      );
                    },
                  ),
                ),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              barGroups: barGroups,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) {
                  return FlLine(
                      color: Colors.grey.shade300.withOpacity(0.5),
                      strokeWidth: 0.5);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReportSummaryTable() {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      color: Colors.white.withOpacity(0.8),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: DataTable(
          columnSpacing: 20,
          horizontalMargin: 10,
          headingRowHeight: 35,
          dataRowMinHeight: 30,
          dataRowMaxHeight: 45,
          dataTextStyle: const TextStyle(fontSize: 13, color: Colors.black87),
          headingTextStyle: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
          columns: [
            DataColumn(label: Text(l10n.reportsSummaryHeaderProperty)),
            DataColumn(
                label: Text(l10n.reportsSummaryHeaderValue), numeric: true),
          ],
          rows: [
            DataRow(cells: [
              DataCell(Text(l10n.reportsSummaryTotalTurnover)),
              DataCell(Text(CurrencyFormatter.format(totalTurnover))),
            ]),
            DataRow(cells: [
              DataCell(Text(l10n.reportsSummaryTotalOrders)),
              DataCell(Text(totalOrders.toString())),
            ]),
            DataRow(cells: [
              DataCell(Text(l10n.reportsSummaryBestSelling)),
              DataCell(Text(bestSellingItem != null
                  ? "${bestSellingItem!['name']} (${l10n.reportsSummaryItemCount(bestSellingItem!['total_sold'])})"
                  : l10n.reportsSummaryNoData)),
            ]),
            DataRow(cells: [
              DataCell(Text(l10n.reportsSummaryLeastSelling)),
              DataCell(Text(leastSellingItem != null
                  ? "${leastSellingItem!['name']} (${l10n.reportsSummaryItemCount(leastSellingItem!['total_sold'])})"
                  : l10n.reportsSummaryNoData)),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final Map<String, String> filterDisplayNames = {
      'day': l10n.reportsFilterToday,
      'week': l10n.reportsFilterThisWeek,
      'month': l10n.reportsFilterThisMonth,
      'year': l10n.reportsFilterThisYear,
      'custom': l10n.reportsFilterCustom,
    };

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.reportsScreenTitle(filterDisplayNames[selectedFilter] ?? ''),
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
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
          IconButton(
            icon: _isExporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.download_for_offline_outlined,
                    color: Colors.white),
            tooltip: l10n.reportsExportToExcelTooltip,
            onPressed: _isExporting ? null : _exportReport,
          ),
        ],
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
        child: SafeArea(
          child: isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : RefreshIndicator(
                  onRefresh: fetchReport,
                  color: Colors.white,
                  backgroundColor: Colors.blue.shade700,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Card(
                          color: Colors.white.withOpacity(0.85),
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12.0, vertical: 4.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      isExpanded: true,
                                      value: selectedFilter,
                                      dropdownColor: Colors.blueGrey[50],
                                      style: const TextStyle(
                                          color: Colors.black87, fontSize: 16),
                                      items: filterDisplayNames.entries
                                          .map((entry) {
                                        return DropdownMenuItem<String>(
                                          value: entry.key,
                                          child: Text(entry.value),
                                        );
                                      }).toList(),
                                      onChanged: (value) {
                                        if (value != null) {
                                          setState(() {
                                            selectedFilter = value;
                                            if (value != 'custom') {
                                              customDateRange = null;
                                              fetchReport();
                                            } else if (value == 'custom' &&
                                                customDateRange == null) {
                                              _pickDateRange();
                                            } else if (value == 'custom' &&
                                                customDateRange != null) {
                                              fetchReport();
                                            }
                                          });
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                if (selectedFilter == 'custom')
                                  IconButton(
                                    icon: Icon(Icons.date_range,
                                        color:
                                            Theme.of(context).primaryColorDark),
                                    tooltip: l10n.reportsPickDateTooltip,
                                    onPressed: _pickDateRange,
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (selectedFilter == 'custom' &&
                            customDateRange != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0, bottom: 4.0),
                            child: Card(
                              color: Colors.white.withOpacity(0.8),
                              elevation: 2,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.calendar_today,
                                        size: 16, color: Colors.grey[700]),
                                    const SizedBox(width: 8),
                                    Text(
                                      l10n.reportsSelectedDateRange(
                                        DateFormat('dd/MM/yy', l10n.localeName)
                                            .format(customDateRange!.start),
                                        DateFormat('dd/MM/yy', l10n.localeName)
                                            .format(customDateRange!.end),
                                      ),
                                      style: TextStyle(
                                          fontWeight: FontWeight.w500,
                                          color: Colors.grey[800]),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (errorMessage.isNotEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 16.0),
                            child: Text(errorMessage,
                                style: const TextStyle(
                                    color: Colors.orangeAccent, fontSize: 16),
                                textAlign: TextAlign.center),
                          ),
                        _buildReportSummaryTable(),
                        const SizedBox(height: 16),
                        Text(chartTitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white.withOpacity(0.9))),
                        const SizedBox(height: 8),
                        _buildTurnoverChart(),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}