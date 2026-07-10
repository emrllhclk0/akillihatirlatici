import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:call_log/call_log.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:background_sms/background_sms.dart';
import 'package:app_settings/app_settings.dart';
import 'screens/onboarding_screen.dart';

// ============================================================================
// Supabase Veritabanı Bağlantı Konfigürasyonu
// ============================================================================

const String supabaseUrl = 'https://occhaqzsvcyullhnwdjp.supabase.co';
const String supabaseAnonKey = 'sb_publishable_PkoeIRJfalNu2LKAsZkipA_jB2UOF3H';

// ============================================================================
// Uygulama Tasarım Sabitleri
// ============================================================================

class AppTheme {
  AppTheme._();
  static const Color primary = Color(0xFF6C63FF);
  static const Color primaryLight = Color(0xFFEEECFF);
  static const Color background = Color(0xFFF8F9FD);
  static const Color cardColor = Colors.white;
  static const Color textPrimary = Color(0xFF1E1E2D);
  static const Color textSecondary = Color(0xFF7C7C8D);
  static const Color callIncoming = Color(0xFF4CAF50);
  static const Color callOutgoing = Color(0xFF2196F3);
  static const Color callMissed = Color(0xFFEF5350);
  static const Color whatsapp = Color(0xFF25D366);
  static const Color deleteRed = Color(0xFFFF3B30);
  static const Color success = Color(0xFF34C759);
  static const double cardRadius = 16.0;
  static const double smallRadius = 12.0;
}

// ============================================================================
// Cihaz İzolasyonu (Device ID)
// ============================================================================

Future<String> getDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  String? deviceId = prefs.getString('device_id');
  if (deviceId == null) {
    deviceId = const Uuid().v4();
    await prefs.setString('device_id', deviceId);
  }
  return deviceId;
}

// ============================================================================
// Yerel Bildirim Eklentisi Tanımlaması
// ============================================================================

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ============================================================================
// Uygulama Giriş Noktası
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));

  await Permission.notification.request();
  await Permission.scheduleExactAlarm.request();
  await Permission.sms.request(); // Toplantı modu için SMS izni
  await Permission.phone.request(); // Toplantı modu arama kaydı okuma

  bool isGranted = await NotificationListenerService.isPermissionGranted();
  if (!isGranted) {
    await NotificationListenerService.requestPermission();
  }

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );

  await flutterLocalNotificationsPlugin.initialize(
    settings: initializationSettings,
  );

  const AndroidNotificationChannel alarmChannel = AndroidNotificationChannel(
    'hatirlatici_alarm_kanali',
    'Hatırlatıcı Alarmları',
    description: 'Seçilen saatte kullanıcıya hatırlatma yapar',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    showBadge: true,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(alarmChannel);

  // ignore: deprecated_member_use
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  await getDeviceId(); // UUID oluştur/al
  await initializeBackgroundService();
  runApp(const MyApp());
}

// ============================================================================
// Zamanlanmış Bildirim Yönetimi
// ============================================================================

Future<void> zamanliBildirimKur(
  int id,
  String baslik,
  String icerik,
  DateTime secilenZaman,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final bool insistent = prefs.getBool('insistent_alarm') ?? false;

    final tz.TZDateTime planlananZaman = tz.TZDateTime.from(
      secilenZaman,
      tz.local,
    );

    AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
          'hatirlatici_alarm_kanali',
          'Hatırlatıcı Alarmları',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
          additionalFlags: insistent ? Int32List.fromList([4]) : null, // FLAG_INSISTENT (4)
        );

    NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await flutterLocalNotificationsPlugin.zonedSchedule(
      id: id,
      title: baslik,
      body: icerik,
      scheduledDate: planlananZaman,
      notificationDetails: platformChannelSpecifics,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  } catch (e) {
    debugPrint("Bildirim zamanlama hatası: $e");
  }
}

// ============================================================================
// Arka Plan Servisi Yapılandırması
// ============================================================================

Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'iletisim_asistani_arka_plan',
    'İletişim Asistanı Servisi',
    importance: Importance.high,
  );

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'iletisim_asistani_arka_plan',
      initialNotificationTitle: 'DönüşYap Aktif',
      initialNotificationContent: 'Arka planda bildirimler takip ediliyor...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onBackground: (service) => false,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ignore: deprecated_member_use
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  final supabase = Supabase.instance.client;

  final prefs = await SharedPreferences.getInstance();
  String deviceId = prefs.getString('device_id') ?? 'unknown';

  Map<String, DateTime> processedMessages = {};
  Map<String, DateTime> lastSmsSent = {};

  NotificationListenerService.notificationsStream.listen((event) async {
    final packageName = event.packageName.toLowerCase();
    final contentLower = event.content.toLowerCase();
    final titleLower = event.title.toLowerCase();

    // ------------------------------------------------------------------------
    // TOPLANTI MODU (CEVAPSIZ ARAMA SMS YANITI)
    // ------------------------------------------------------------------------
    if (packageName.contains('dialer') || packageName.contains('telecom') || packageName.contains('incallui') || packageName.contains('contacts')) {
      if (contentLower.contains('cevapsız') || titleLower.contains('cevapsız') || contentLower.contains('missed') || titleLower.contains('missed')) {
        await prefs.reload(); 
        final bool meetingMode = prefs.getBool('meeting_mode') ?? false;
        final String meetingMessage = prefs.getString('meeting_message') ?? "Şu an toplantıdayım, size döneceğim.";
        final String filterMode = prefs.getString('filter_mode') ?? 'Tümü';
        final List<String> numberList = prefs.getStringList('number_list') ?? [];
        
        if (meetingMode) {
          try {
            Iterable<CallLogEntry> entries = await CallLog.query(
              dateFrom: DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch,
            );
            
            for (var entry in entries) {
              if (entry.callType == CallType.missed && entry.number != null && entry.number!.isNotEmpty) {
                String number = entry.number!;
                
                // Filtre Modu Kontrolü
                bool canSend = true;
                if (filterMode == 'VIP') {
                  canSend = numberList.any((n) => number.contains(n) || n.contains(number));
                } else if (filterMode == 'Kara Liste') {
                  canSend = !numberList.any((n) => number.contains(n) || n.contains(number));
                }
                
                if (!canSend) {
                  debugPrint("Toplantı Modu SMS reddedildi ($filterMode) - Numara: $number");
                  break; // Sadece listeye takıldık, işlemi bitir
                }

                if (lastSmsSent.containsKey(number) && DateTime.now().difference(lastSmsSent[number]!).inMinutes < 5) {
                  continue; 
                }
                
                var status = await Permission.sms.status;
                if (status.isGranted) {
                  SmsStatus result = await BackgroundSms.sendMessage(phoneNumber: number, message: meetingMessage);
                  if (result == SmsStatus.sent) {
                    lastSmsSent[number] = DateTime.now();
                  }
                }
                break; 
              }
            }
          } catch (e) {
            debugPrint("Toplantı Modu SMS Hatası: $e");
          }
        }
      }
    }

    // ------------------------------------------------------------------------
    // WHATSAPP KONTROLÜ
    // ------------------------------------------------------------------------
    if (packageName == 'com.whatsapp' && event.content.isNotEmpty) {
      String content = event.content.trim();
      String sender = event.title.isEmpty ? 'Bilinmeyen Kişi' : event.title.trim();

      if (contentLower.contains('yeni mesaj') || contentLower.contains('new message') || sender.toLowerCase() == 'whatsapp') {
        return;
      }
      if (contentLower.startsWith('siz:') || contentLower.startsWith('sen:') || contentLower.startsWith('you:')) {
        return;
      }

      String msgKey = "$sender:$content";
      if (processedMessages.containsKey(msgKey)) {
        if (DateTime.now().difference(processedMessages[msgKey]!).inSeconds < 5) {
          return;
        }
      }

      if (processedMessages.length > 100) processedMessages.clear();
      processedMessages[msgKey] = DateTime.now();

      try {
        final existing = await supabase
            .from('reminders')
            .select('id')
            .eq('device_id', deviceId)
            .eq('sender_name', sender)
            .eq('message_content', content)
            .gte('scheduled_time', DateTime.now().subtract(const Duration(hours: 1)).toIso8601String())
            .limit(1);

        if (existing.isEmpty) {
          await supabase.from('reminders').insert({
            'device_id': deviceId,
            'sender_name': sender,
            'message_content': content,
            'scheduled_time': DateTime.now().toIso8601String(),
          });
        }
      } catch (e) {
        debugPrint("Veritabanına kayıt veya kontrol yapılamadı: $e");
      }
    }
  });
}

// ============================================================================
// Ortak Yardımcı Fonksiyonlar
// ============================================================================

Future<DateTime?> pickReminderDateTime(BuildContext context) async {
  final DateTime? date = await showDatePicker(
    context: context,
    initialDate: DateTime.now(),
    firstDate: DateTime.now(),
    lastDate: DateTime.now().add(const Duration(days: 365)),
  );

  if (date == null || !context.mounted) return null;

  final TimeOfDay? time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.now(),
  );

  if (time == null) return null;

  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

String formatDateTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);

  if (diff.inMinutes < 1) return 'Az önce';
  if (diff.inMinutes < 60) return '${diff.inMinutes} dk önce';
  if (diff.inHours < 24) return '${diff.inHours} saat önce';
  if (diff.inDays < 7) return '${diff.inDays} gün önce';

  return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
}

String getInitials(String name) {
  final parts = name.trim().split(' ');
  if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  return name.isNotEmpty ? name[0].toUpperCase() : '?';
}

// ============================================================================
// Boş Durum Bileşeni
// ============================================================================

class BosDurumBileseni extends StatelessWidget {
  final IconData icon;
  final String mesaj;
  final String? altMesaj;

  const BosDurumBileseni({
    super.key,
    required this.icon,
    required this.mesaj,
    this.altMesaj,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: AppTheme.primaryLight, shape: BoxShape.circle),
              child: Icon(icon, size: 56, color: AppTheme.primary.withValues(alpha: 0.5)),
            ),
            const SizedBox(height: 24),
            Text(
              mesaj,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
            ),
            if (altMesaj != null) ...[
              const SizedBox(height: 8),
              Text(
                altMesaj!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Ana Uygulama Bileşeni
// ============================================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DönüşYap',
      themeMode: ThemeMode.light,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.primary, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF8F9FD),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          backgroundColor: Color(0xFFF8F9FD),
          foregroundColor: Color(0xFF1E1E2D),
          titleTextStyle: TextStyle(color: Color(0xFF1E1E2D), fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5),
          systemOverlayStyle: SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.dark),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.cardRadius), side: BorderSide(color: Colors.grey.shade200)),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.smallRadius)),
        ),
      ),
      home: const _AppEntry(),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();
  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _showOnboarding = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final show = prefs.getBool('show_onboarding') ?? true;
    setState(() {
      _showOnboarding = show;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return _showOnboarding ? const OnboardingScreen() : const MainScreen();
  }
}

// ============================================================================
// Ana Ekran Navigasyon Yönetimi
// ============================================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const DashboardScreen(),
    const CallLogsScreen(),
    const RemindersScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _screens[_currentIndex],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, -2))],
        ),
        child: NavigationBar(
          height: 68,
          elevation: 0,
          backgroundColor: Colors.white,
          indicatorColor: AppTheme.primaryLight,
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) => setState(() => _currentIndex = index),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard, color: AppTheme.primary), label: 'Görevler'),
            NavigationDestination(icon: Icon(Icons.phone_outlined), selectedIcon: Icon(Icons.phone, color: AppTheme.primary), label: 'Aramalar'),
            NavigationDestination(icon: Icon(Icons.chat_outlined), selectedIcon: Icon(Icons.chat, color: AppTheme.primary), label: 'WhatsApp'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings, color: AppTheme.primary), label: 'Ayarlar'),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Arama Geçmişi Ekranı
// ============================================================================

class CallLogsScreen extends StatefulWidget {
  const CallLogsScreen({super.key});
  @override
  State<CallLogsScreen> createState() => _CallLogsScreenState();
}

class _CallLogsScreenState extends State<CallLogsScreen> {
  List<CallLogEntry> _callLogEntries = [];
  bool _isLoading = true;
  String _filter = 'Tümü'; // 'Tümü', 'Cevapsız', 'Hatırlatıcı'
  late String _deviceId;

  @override
  void initState() {
    super.initState();
    _initAndFetch();
  }

  Future<void> _initAndFetch() async {
    _deviceId = await getDeviceId();
    await _fetchAndSyncCallLogs();
  }

  Future<void> _fetchAndSyncCallLogs() async {
    setState(() => _isLoading = true);
    var status = await Permission.phone.request();

    if (status.isGranted) {
      try {
        int from = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
        Iterable<CallLogEntry> allEntries = await CallLog.query(dateFrom: from);
        List<CallLogEntry> recentEntries = allEntries.take(100).toList();

        setState(() {
          _callLogEntries = recentEntries;
          _isLoading = false;
        });
        _syncWithSupabase(recentEntries);
      } catch (e) {
        setState(() => _isLoading = false);
      }
    } else {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _syncWithSupabase(List<CallLogEntry> entries) async {
    final supabase = Supabase.instance.client;
    try {
      List<Map<String, dynamic>> bulkData = [];
      for (var entry in entries) {
        String callTypeStr = entry.callType == CallType.incoming ? 'Gelen' : entry.callType == CallType.outgoing ? 'Giden' : entry.callType == CallType.missed ? 'Cevapsız' : 'Bilinmeyen';

        bulkData.add({
          'device_id': _deviceId,
          'phone_number': entry.number ?? '0000',
          'caller_name': entry.name?.isNotEmpty == true ? entry.name : 'Bilinmeyen',
          'duration_seconds': entry.duration ?? 0,
          'call_type': callTypeStr,
          'call_timestamp': DateTime.fromMillisecondsSinceEpoch(entry.timestamp ?? 0).toIso8601String(),
        });
      }
      if (bulkData.isNotEmpty) {
        for (var item in bulkData) {
          try {
            await supabase.from('call_logs').insert(item);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _setReminder(CallLogEntry entry) async {
    DateTime? picked = await pickReminderDateTime(context);
    if (picked != null) {
      final timestampStr = DateTime.fromMillisecondsSinceEpoch(entry.timestamp ?? 0).toIso8601String();
      try {
        final resp = await Supabase.instance.client
            .from('call_logs')
            .update({'is_reminder_set': true, 'reminder_time': picked.toIso8601String()})
            .eq('device_id', _deviceId)
            .eq('call_timestamp', timestampStr)
            .select();

        if (resp.isEmpty) {
          String callTypeStr = entry.callType == CallType.incoming ? 'Gelen' : entry.callType == CallType.outgoing ? 'Giden' : entry.callType == CallType.missed ? 'Cevapsız' : 'Bilinmeyen';
          await Supabase.instance.client.from('call_logs').insert({
            'device_id': _deviceId,
            'phone_number': entry.number ?? '0000',
            'caller_name': entry.name?.isNotEmpty == true ? entry.name : 'Bilinmeyen',
            'duration_seconds': entry.duration ?? 0,
            'call_type': callTypeStr,
            'call_timestamp': timestampStr,
            'is_reminder_set': true,
            'reminder_time': picked.toIso8601String()
          });
        }

        int notificationId = int.tryParse((entry.number ?? "1234").replaceAll(RegExp(r'[^0-9]'), '').characters.takeLast(4).toString()) ?? 1000;
        String name = entry.name?.isNotEmpty == true ? entry.name! : (entry.number ?? 'Bilinmeyen');

        await zamanliBildirimKur(notificationId, "📞 Arama Hatırlatıcı", "$name kişisini aramanız gerekiyor.", picked);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Hatırlatıcı kuruldu'), backgroundColor: AppTheme.success));
          _fetchAndSyncCallLogs();
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e'), backgroundColor: AppTheme.deleteRed));
      }
    }
  }

  void _removeCallLogEntry(int index) {
    setState(() => _callLogEntries.removeAt(index));
  }
  
  Future<void> _callNumber(String number) async {
    final Uri launchUri = Uri(scheme: 'tel', path: number);
    try {
      await launchUrl(launchUri);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Arama başlatılamadı.')));
    }
  }

  Color _getCallTypeColor(CallType? type) {
    switch (type) {
      case CallType.incoming: return AppTheme.callIncoming;
      case CallType.outgoing: return AppTheme.callOutgoing;
      case CallType.missed: return AppTheme.callMissed;
      default: return AppTheme.textSecondary;
    }
  }

  IconData _getCallTypeIcon(CallType? type) {
    switch (type) {
      case CallType.incoming: return Icons.call_received_rounded;
      case CallType.outgoing: return Icons.call_made_rounded;
      case CallType.missed: return Icons.call_missed_rounded;
      default: return Icons.call_rounded;
    }
  }

  String _formatDuration(int? seconds) {
    if (seconds == null || seconds == 0) return '0 sn';
    if (seconds < 60) return '$seconds sn';
    final min = seconds ~/ 60;
    final sec = seconds % 60;
    return sec > 0 ? '$min dk $sec sn' : '$min dk';
  }

  @override
  Widget build(BuildContext context) {
    List<CallLogEntry> filteredList = _callLogEntries.where((entry) {
      if (_filter == 'Cevapsız') return entry.callType == CallType.missed;
      return true; 
    }).toList();

    // Akıllı Önceliklendirme Gruplaması (Son 24 saat cevapsızlar)
    Map<String, int> missedCounts = {};
    for (var entry in _callLogEntries) {
      if (entry.callType == CallType.missed && entry.number != null) {
        DateTime t = DateTime.fromMillisecondsSinceEpoch(entry.timestamp ?? 0);
        if (DateTime.now().difference(t).inHours < 24) {
           missedCounts[entry.number!] = (missedCounts[entry.number!] ?? 0) + 1;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aramalar'),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 22),
              style: IconButton.styleFrom(backgroundColor: AppTheme.primaryLight, foregroundColor: AppTheme.primary),
              onPressed: _fetchAndSyncCallLogs,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: ['Tümü', 'Cevapsız'].map((String filterName) {
                final isSelected = _filter == filterName;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(filterName),
                    selected: isSelected,
                    onSelected: (bool selected) {
                      setState(() => _filter = filterName);
                    },
                    selectedColor: AppTheme.primaryLight,
                    checkmarkColor: AppTheme.primary,
                    labelStyle: TextStyle(
                      color: isSelected ? AppTheme.primary : AppTheme.textSecondary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 3))
          : filteredList.isEmpty
          ? const BosDurumBileseni(icon: Icons.phone_disabled_outlined, mesaj: 'Arama kaydı bulunamadı')
          : RefreshIndicator(
              color: AppTheme.primary,
              onRefresh: _fetchAndSyncCallLogs,
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                itemCount: filteredList.length,
                itemBuilder: (context, index) {
                  var entry = filteredList[index];
                  String displayName = entry.name?.isNotEmpty == true ? entry.name! : (entry.number ?? 'Bilinmeyen');
                  final callColor = _getCallTypeColor(entry.callType);
                  final callIcon = _getCallTypeIcon(entry.callType);
                  final callTime = DateTime.fromMillisecondsSinceEpoch(entry.timestamp ?? 0);
                  
                  int mCount = missedCounts[entry.number] ?? 0;
                  bool isUrgent = (entry.callType == CallType.missed && mCount >= 3);

                  return Dismissible(
                    key: ValueKey('${entry.number}_${entry.timestamp}_$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 28.0),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                      decoration: BoxDecoration(color: AppTheme.deleteRed, borderRadius: BorderRadius.circular(AppTheme.cardRadius)),
                      child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 24),
                    ),
                    onDismissed: (direction) => _removeCallLogEntry(index),
                    child: Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                        side: BorderSide(
                          color: isUrgent ? Colors.red.shade400 : Colors.grey.shade100,
                          width: isUrgent ? 1.5 : 1.0,
                        )
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isUrgent)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text("🚨 Acil ($mCount Cevapsız Çağrı)", style: TextStyle(color: Colors.red.shade600, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
                              ),
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: callColor.withValues(alpha: 0.12),
                                  child: Text(getInitials(displayName), style: TextStyle(color: callColor, fontWeight: FontWeight.w700, fontSize: 15)),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(displayName, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: AppTheme.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        crossAxisAlignment: WrapCrossAlignment.center,
                                        spacing: 4,
                                        children: [
                                          Icon(callIcon, size: 14, color: callColor),
                                          Text(formatDateTime(callTime), style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                          Text('·', style: TextStyle(color: AppTheme.textSecondary)),
                                          Text(_formatDuration(entry.duration), style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                
                                // Aksiyon Butonları
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.phone, color: AppTheme.primary, size: 22),
                                      onPressed: () => _callNumber(entry.number ?? ''),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 16),
                                    IconButton(
                                      icon: const Icon(Icons.alarm_add_rounded, color: AppTheme.primary, size: 24),
                                      onPressed: () => _setReminder(entry),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ============================================================================
// WhatsApp Mesaj Kayıtları Ekranı
// ============================================================================

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});
  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  bool _isLoading = true;
  List<dynamic> _dbMessages = [];
  String _filter = 'Tümü'; // 'Tümü', 'Hatırlatıcı Bekleyenler'
  late String _deviceId;

  @override
  void initState() {
    super.initState();
    _initAndFetch();
  }

  Future<void> _initAndFetch() async {
    _deviceId = await getDeviceId();
    await _fetchMessagesFromDB();
  }

  Future<void> _fetchMessagesFromDB() async {
    setState(() => _isLoading = true);
    try {
      var query = Supabase.instance.client
          .from('reminders')
          .select()
          .eq('device_id', _deviceId)
          .order('scheduled_time', ascending: false)
          .limit(50);
          
      final data = await query;
      setState(() {
        _dbMessages = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _setReminder(dynamic msg) async {
    DateTime? picked = await pickReminderDateTime(context);
    if (picked != null) {
      try {
        await Supabase.instance.client
            .from('reminders')
            .update({'is_reminder_set': true, 'reminder_time': picked.toIso8601String()})
            .eq('id', msg['id']);

        int notifId = (msg['id'] is int) ? msg['id'] : int.tryParse(msg['id'].toString()) ?? 999;
        String sender = msg['sender_name'] ?? 'Bilinmeyen';

        await zamanliBildirimKur(notifId, "💬 WhatsApp Hatırlatıcı", "$sender kişisine mesaj atmanız gerekiyor.", picked);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Hatırlatıcı kuruldu'), backgroundColor: AppTheme.success));
        _fetchMessagesFromDB();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e'), backgroundColor: AppTheme.deleteRed));
      }
    }
  }

  Future<void> _deleteReminderFromDB(dynamic msg) async {
    try {
      await Supabase.instance.client.from('reminders').delete().eq('id', msg['id']);
      setState(() {
        _dbMessages.removeWhere((element) => element['id'] == msg['id']);
      });
    } catch (_) {}
  }

  Future<void> _openWhatsApp() async {
    final Uri whatsappUrl = Uri.parse("whatsapp://send");
    try {
      bool launched = await launchUrl(whatsappUrl, mode: LaunchMode.externalApplication);
      if (!launched) {
        final Uri webUrl = Uri.parse("https://wa.me/");
        await launchUrl(webUrl, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WhatsApp başlatılamadı. Cihazınızda yüklü olduğundan emin olun.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    List<dynamic> filteredList = _dbMessages.where((msg) {
      if (_filter == 'Hatırlatıcı Kurulanlar') return msg['is_reminder_set'] == true;
      if (_filter == 'Bekleyenler') return msg['is_reminder_set'] != true;
      return true;
    }).toList();

    // Akıllı Önceliklendirme Gruplaması (Aynı kişiden kaç mesaj)
    Map<String, int> msgCounts = {};
    for (var msg in _dbMessages) {
       String sender = msg['sender_name'] ?? 'Bilinmeyen';
       msgCounts[sender] = (msgCounts[sender] ?? 0) + 1;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('WhatsApp'),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 22),
              style: IconButton.styleFrom(backgroundColor: AppTheme.whatsapp.withValues(alpha: 0.12), foregroundColor: AppTheme.whatsapp),
              onPressed: _fetchMessagesFromDB,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: ['Tümü', 'Bekleyenler', 'Hatırlatıcı Kurulanlar'].map((String filterName) {
                final isSelected = _filter == filterName;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(filterName),
                    selected: isSelected,
                    onSelected: (bool selected) {
                      setState(() => _filter = filterName);
                    },
                    selectedColor: AppTheme.whatsapp.withValues(alpha: 0.15),
                    checkmarkColor: AppTheme.whatsapp,
                    labelStyle: TextStyle(
                      color: isSelected ? AppTheme.whatsapp : AppTheme.textSecondary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: AppTheme.whatsapp, strokeWidth: 3))
          : filteredList.isEmpty
          ? const BosDurumBileseni(icon: Icons.chat_bubble_outline_rounded, mesaj: 'Mesaj kaydı bulunamadı')
          : RefreshIndicator(
              color: AppTheme.whatsapp,
              onRefresh: _fetchMessagesFromDB,
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                itemCount: filteredList.length,
                itemBuilder: (context, index) {
                  var msg = filteredList[index];
                  bool isReminderSet = msg['is_reminder_set'] == true;
                  String senderName = msg['sender_name'] ?? 'Bilinmeyen';
                  String messageContent = msg['message_content'] ?? '';
                  DateTime time = DateTime.tryParse(msg['scheduled_time'] ?? '') ?? DateTime.now();

                  int count = msgCounts[senderName] ?? 0;
                  bool isUrgent = count >= 3;

                  return Dismissible(
                    key: ValueKey(msg['id']),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 28.0),
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                      decoration: BoxDecoration(color: AppTheme.deleteRed, borderRadius: BorderRadius.circular(AppTheme.cardRadius)),
                      child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 24),
                    ),
                    onDismissed: (direction) => _deleteReminderFromDB(msg),
                    child: Card(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
                        side: BorderSide(
                          color: isUrgent ? Colors.orange.shade400 : Colors.grey.shade100,
                          width: isUrgent ? 1.5 : 1.0,
                        )
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isUrgent)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text("🔥 Yüksek Öncelikli ($count Mesaj)", style: TextStyle(color: Colors.orange.shade700, fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
                              ),
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: AppTheme.whatsapp.withValues(alpha: 0.12),
                                  child: Text(getInitials(senderName), style: const TextStyle(color: AppTheme.whatsapp, fontWeight: FontWeight.w700, fontSize: 15)),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(child: Text(senderName, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: AppTheme.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                          Text(formatDateTime(time), style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(messageContent, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary, height: 1.3), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                
                                // Aksiyon Butonları
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.open_in_new_rounded, color: AppTheme.whatsapp, size: 22),
                                      onPressed: () => _openWhatsApp(),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                    const SizedBox(width: 12),
                                    IconButton(
                                      icon: Icon(isReminderSet ? Icons.alarm_on_rounded : Icons.alarm_add_rounded, color: isReminderSet ? AppTheme.success : AppTheme.primary, size: 24),
                                      onPressed: () => _setReminder(msg),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

// ============================================================================
// Ayarlar ve Toplantı Modu Ekranı
// ============================================================================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _meetingMode = false;
  String _filterMode = 'Tümü';
  List<String> _numberList = [];
  bool _insistentAlarm = false;
  
  List<String> _vipList = [];
  List<String> _blacklist = [];

  final TextEditingController _vipController = TextEditingController();
  final TextEditingController _blacklistController = TextEditingController();
  
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _numberController = TextEditingController();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _meetingMode = prefs.getBool('meeting_mode') ?? false;
      _messageController.text = prefs.getString('meeting_message') ?? "Şu an toplantıdayım, size döneceğim.";
      _filterMode = prefs.getString('filter_mode') ?? 'Tümü';
      _numberList = prefs.getStringList('number_list') ?? [];
      _insistentAlarm = prefs.getBool('insistent_alarm') ?? false;
      _vipList = prefs.getStringList('vip_list') ?? [];
      _blacklist = prefs.getStringList('blacklist') ?? [];

      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('meeting_mode', _meetingMode);
    await prefs.setString('meeting_message', _messageController.text);
    await prefs.setString('filter_mode', _filterMode);
    await prefs.setStringList('number_list', _numberList);
    await prefs.setBool('insistent_alarm', _insistentAlarm);
    await prefs.setStringList('vip_list', _vipList);
    await prefs.setStringList('blacklist', _blacklist);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ayarlar kaydedildi.'), backgroundColor: AppTheme.success));
  }
  
  void _addNumber() {
    String number = _numberController.text.trim();
    if (number.isNotEmpty && !_numberList.contains(number)) {
      setState(() {
        _numberList.add(number);
        _numberController.clear();
      });
      _saveSettings();
    }
  }

  void _removeNumber(String number) {
    setState(() {
      _numberList.remove(number);
    });
    _saveSettings();
  }

  void _addVip() {
    String val = _vipController.text.trim();
    if (val.isNotEmpty && !_vipList.contains(val)) {
      setState(() { _vipList.add(val); _vipController.clear(); });
      _saveSettings();
    }
  }
  void _removeVip(String val) { setState(() => _vipList.remove(val)); _saveSettings(); }
  void _addBlacklist() {
    String val = _blacklistController.text.trim();
    if (val.isNotEmpty && !_blacklist.contains(val)) {
      setState(() { _blacklist.add(val); _blacklistController.clear(); });
      _saveSettings();
    }
  }
  void _removeBlacklist(String val) { setState(() => _blacklist.remove(val)); _saveSettings(); }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Alarm Ayarları
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.blue.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.alarm_on_rounded, color: Colors.blue.shade700),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Israrcı Alarm Modu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                            Text('Alarm çalarken manuel kapatana kadar titrer', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                      Switch(
                        value: _insistentAlarm,
                        activeTrackColor: AppTheme.primary,
                        onChanged: (val) {
                          setState(() => _insistentAlarm = val);
                          _saveSettings();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Toplantı Modu Kartı
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.orange.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.do_not_disturb_on_rounded, color: Colors.orange.shade700),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Toplantı Modu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                            Text('Cevapsız aramalara SMS atar', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                      Switch(
                        value: _meetingMode,
                        activeTrackColor: AppTheme.primary,
                        onChanged: (val) {
                          setState(() => _meetingMode = val);
                          _saveSettings();
                        },
                      ),
                    ],
                  ),
                  if (_meetingMode) ...[
                    const Divider(height: 24),
                    Text('Otomatik Yanıt Mesajı', style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _messageController,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Mesajınızı buraya yazın...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: AppTheme.background,
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    Text('Filtre Modu', style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: AppTheme.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _filterMode,
                          items: ['Tümü', 'VIP', 'Kara Liste'].map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(value),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _filterMode = val);
                              _saveSettings();
                            }
                          },
                        ),
                      ),
                    ),
                    
                    if (_filterMode != 'Tümü') ...[
                      const SizedBox(height: 16),
                      Text(_filterMode == 'VIP' ? 'Sadece bu numaralara SMS atılacak:' : 'Bu numaralara SMS ATILMAYACAK:', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _numberController,
                              keyboardType: TextInputType.phone,
                              decoration: InputDecoration(
                                hintText: 'Örn: 0555...',
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _addNumber,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Ekle'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_numberList.isEmpty)
                        const Text('Liste henüz boş', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 13))
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _numberList.map((numText) => Chip(
                            label: Text(numText, style: const TextStyle(fontSize: 13)),
                            deleteIcon: const Icon(Icons.close, size: 16),
                            onDeleted: () => _removeNumber(numText),
                            backgroundColor: _filterMode == 'VIP' ? Colors.green.shade50 : Colors.red.shade50,
                            side: BorderSide(color: _filterMode == 'VIP' ? Colors.green.shade200 : Colors.red.shade200),
                          )).toList(),
                        ),
                    ],
                    
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saveSettings,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Mesajı Kaydet'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          
          // Hızlı SMS Şablonları
          if (_meetingMode) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.flash_on, size: 16),
                    label: const Text('Toplantıdayım'),
                    onPressed: () {
                      _messageController.text = 'Şu an toplantıdayım, sonra döneceğim.';
                      _saveSettings();
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.directions_car, size: 16),
                    label: const Text('Araçtayım'),
                    onPressed: () {
                      _messageController.text = 'Araç kullanıyorum, acilse mesaj atın.';
                      _saveSettings();
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.movie, size: 16),
                    label: const Text('Sinemadayım'),
                    onPressed: () {
                      _messageController.text = 'Sinemadayım, müsait olunca arayacağım.';
                      _saveSettings();
                    },
                  ),
                ],
              ),
            ),
          ],
          
          const SizedBox(height: 16),

          // Arka Plan Çalışma İzni Kartı
          Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppTheme.cardRadius),
              onTap: () => AppSettings.openAppSettings(),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.battery_saver, color: Colors.green.shade700),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Arka Plan Çalışma İzni', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                          Text('Pil optimizasyonunu kapatarak kesintisiz çalışın', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: AppTheme.textSecondary),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // VIP Kişiler Kartı
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.green.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.star_rounded, color: Colors.green.shade700),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('VIP Kişiler', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                            Text('Ayrıcalıklı kişiler listesi', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _vipController,
                          decoration: InputDecoration(
                            hintText: 'Kişi Adı veya Numara',
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addVip,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.green.shade600,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Ekle'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_vipList.isEmpty)
                    const Text('Liste henüz boş', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 13))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _vipList.map((val) => Chip(
                        label: Text(val, style: const TextStyle(fontSize: 13)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => _removeVip(val),
                        backgroundColor: Colors.green.shade50,
                        side: BorderSide(color: Colors.green.shade200),
                      )).toList(),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Kara Liste Kartı
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: Colors.red.shade100, borderRadius: BorderRadius.circular(8)),
                        child: Icon(Icons.block_rounded, color: Colors.red.shade700),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Kara Liste', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.textPrimary)),
                            Text('Bu kişilerden gelen SMS/WhatsApp izlenmez', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _blacklistController,
                          decoration: InputDecoration(
                            hintText: 'Kişi Adı veya Numara',
                            isDense: true,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _addBlacklist,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade600,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Ekle'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_blacklist.isEmpty)
                    const Text('Liste henüz boş', style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic, fontSize: 13))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _blacklist.map((val) => Chip(
                        label: Text(val, style: const TextStyle(fontSize: 13)),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () => _removeBlacklist(val),
                        backgroundColor: Colors.red.shade50,
                        side: BorderSide(color: Colors.red.shade200),
                      )).toList(),
                    ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Text('GİZLİLİK', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.textSecondary, letterSpacing: 1)),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.security, color: AppTheme.success),
              title: const Text('Cihaz İzolasyonu Aktif'),
              subtitle: const Text('Kayıtlarınız sadece bu cihaza özeldir ve başkası tarafından görülemez.', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PANEL (DASHBOARD) EKRANI
// ============================================================================

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  bool _isLoading = true;
  List<dynamic> _tasks = [];
  late String _deviceId;

  @override
  void initState() {
    super.initState();
    _initAndFetch();
  }

  Future<void> _initAndFetch() async {
    _deviceId = await getDeviceId();
    await _fetchTasks();
  }

  Future<void> _fetchTasks() async {
    setState(() => _isLoading = true);
    try {
      final msgData = await Supabase.instance.client
          .from('reminders')
          .select()
          .eq('device_id', _deviceId)
          .eq('is_reminder_set', true);
          
      final callData = await Supabase.instance.client
          .from('call_logs')
          .select()
          .eq('device_id', _deviceId)
          .eq('is_reminder_set', true);

      List<dynamic> combined = [];
      Set<String> seen = {};

      for (var call in callData) {
        String uniqueKey = 'call_${call['phone_number']}_${call['reminder_time']}';
        if (seen.contains(uniqueKey)) continue;
        seen.add(uniqueKey);

        String idField = call['id'] != null ? 'id' : 'call_timestamp';
        var idVal = call['id'] ?? call['call_timestamp'];
        combined.add({
          'id': 'call_$idVal',
          'real_id': idVal,
          'id_field': idField,
          'contact_name': call['caller_name'],
          'phone_number': call['phone_number'],
          'reminder_time': call['reminder_time'],
          'type': 'call',
        });
      }
      
      for (var msg in msgData) {
        String uniqueKey = 'msg_${msg['sender_name']}_${msg['reminder_time']}';
        if (seen.contains(uniqueKey)) continue;
        seen.add(uniqueKey);

        combined.add({
          'id': 'msg_${msg['id']}',
          'real_id': msg['id'],
          'id_field': 'id',
          'contact_name': msg['sender_name'],
          'phone_number': 'WhatsApp Mesajı',
          'reminder_time': msg['reminder_time'],
          'type': 'msg',
        });
      }
      
      final prefs = await SharedPreferences.getInstance();
      List<String> savedOrder = prefs.getStringList('dashboard_order') ?? [];
      
      if (savedOrder.isNotEmpty) {
        combined.sort((a, b) {
          int indexA = savedOrder.indexOf(a['id'].toString());
          int indexB = savedOrder.indexOf(b['id'].toString());
          
          if (indexA == -1 && indexB == -1) {
            String timeA = a['reminder_time'] ?? '';
            String timeB = b['reminder_time'] ?? '';
            return timeA.compareTo(timeB);
          }
          if (indexA == -1) return -1;
          if (indexB == -1) return 1;

          return indexA.compareTo(indexB);
        });
      } else {
        combined.sort((a, b) {
          String timeA = a['reminder_time'] ?? '';
          String timeB = b['reminder_time'] ?? '';
          return timeA.compareTo(timeB);
        });
      }
      
      if (mounted) {
        setState(() {
          _tasks = combined;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = _tasks.removeAt(oldIndex);
      _tasks.insert(newIndex, item);
    });
    
    final prefs = await SharedPreferences.getInstance();
    List<String> newOrder = _tasks.map((e) => e['id'].toString()).toList();
    await prefs.setStringList('dashboard_order', newOrder);
  }

  Future<void> _completeTask(dynamic task) async {
    final String type = task['type'] ?? 'call';
    
    try {
      if (type == 'call') {
        await Supabase.instance.client
            .from('call_logs')
            .update({'is_reminder_set': false})
            .eq('device_id', _deviceId)
            .eq('phone_number', task['phone_number'])
            .eq('is_reminder_set', true);
      } else {
        await Supabase.instance.client
            .from('reminders')
            .update({'is_reminder_set': false})
            .eq('id', task['real_id']);
      }
      
      if (mounted) {
        setState(() {
          _tasks.removeWhere((t) => t['id'] == task['id']);
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Görev tamamlandı 🎉'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {}
  }

  String _getTimeLeft(String? reminderTime) {
    if (reminderTime == null) return '';
    final dt = DateTime.tryParse(reminderTime);
    if (dt == null) return '';
    final diff = dt.difference(DateTime.now());
    if (diff.isNegative) return 'Süresi geçti';
    if (diff.inDays > 0) return '${diff.inDays} gün sonra';
    if (diff.inHours > 0) return '${diff.inHours} saat sonra';
    if (diff.inMinutes > 0) return '${diff.inMinutes} dk sonra';
    return 'Birazdan';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Görevler', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 26)),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            child: IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 24),
              style: IconButton.styleFrom(backgroundColor: AppTheme.primaryLight, foregroundColor: AppTheme.primary),
              onPressed: _fetchTasks,
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF8B80F9), Color(0xFF6C63FF)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.check_circle_outline, color: Colors.white, size: 32),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${_tasks.length} Bekleyen Görev', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text('Sürükle & bırak ile öncelik sıralayın', style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: _tasks.isEmpty
                      ? const Center(child: Text('Bekleyen görev yok 🎉', style: TextStyle(color: AppTheme.textSecondary)))
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: _tasks.length,
                          onReorder: _onReorder,
                          proxyDecorator: (Widget child, int index, Animation<double> animation) {
                            return Material(
                              elevation: 0,
                              color: Colors.transparent,
                              child: child,
                            );
                          },
                          itemBuilder: (context, index) {
                            final task = _tasks[index];
                            final isCall = (task['type'] ?? 'call') == 'call';
                            
                            bool isOverdue = false;
                            final reminderTimeStr = task['reminder_time'];
                            if (reminderTimeStr != null) {
                              final dt = DateTime.tryParse(reminderTimeStr);
                              if (dt != null && dt.difference(DateTime.now()).isNegative) {
                                isOverdue = true;
                              }
                            }
                            
                            return Padding(
                              key: ValueKey('pad_${task['id']}'),
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Dismissible(
                                key: ValueKey('dismiss_${task['id']}'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.symmetric(horizontal: 28.0),
                                  decoration: BoxDecoration(color: AppTheme.success, borderRadius: BorderRadius.circular(16)),
                                  child: const Icon(Icons.check_circle_outline, color: Colors.white, size: 32),
                                ),
                                onDismissed: (direction) => _completeTask(task),
                                child: Card(
                                  margin: EdgeInsets.zero,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16), 
                                    side: BorderSide(
                                      color: isOverdue ? AppTheme.deleteRed : Colors.grey.shade200,
                                      width: isOverdue ? 1.5 : 1.0,
                                    )
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 24,
                                          backgroundColor: AppTheme.primaryLight,
                                          child: Icon(isCall ? Icons.phone : Icons.chat, color: AppTheme.primary),
                                        ),
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Expanded(child: Text(task['contact_name'] ?? 'Bilinmeyen', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                                  Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                    decoration: BoxDecoration(color: AppTheme.primaryLight, borderRadius: BorderRadius.circular(12)),
                                                    child: Text(isCall ? 'Arama' : 'Mesaj', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppTheme.primary)),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(task['phone_number'] ?? '', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                                              const SizedBox(height: 6),
                                              Row(
                                                children: [
                                                  const Icon(Icons.access_time, size: 14, color: AppTheme.textSecondary),
                                                  const SizedBox(width: 4),
                                                  Text(_getTimeLeft(task['reminder_time']), style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        ReorderableDragStartListener(
                                          index: index,
                                          child: const Icon(Icons.drag_handle, color: AppTheme.textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

