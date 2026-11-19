import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const bg = Color(0xFF0B1210);
const card = Color(0xFF16211D);
const card2 = Color(0xFF1D2B26);
const border = Color(0xFF2D423A);
const gold = Color(0xFFF0CB79);
const green = Color(0xFF8DDBA8);
const red = Color(0xFFF29C91);
const muted = Color(0xFFA5B8B0);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScoreApp());
}

class Backend {
  const Backend(this.name, this.url);
  final String name;
  final String url;
}

const backends = [
  Backend('老后台', 'http://74.82.221.117:8787'),
  Backend('新后台', 'http://102.134.34.160:8787'),
];

class ApiError implements Exception {
  ApiError(this.message, [this.status]);
  final String message;
  final int? status;
  @override String toString() => message;
}

class ScoreApi {
  ScoreApi(this.backend);
  final Backend backend;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  String _cookie = '';

  Future<Map<String, dynamic>> request(String path, {String method = 'GET', Map<String, dynamic>? body}) async {
    final req = await _client.openUrl(method, Uri.parse('${backend.url}$path'));
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
    if (_cookie.isNotEmpty) req.headers.set(HttpHeaders.cookieHeader, _cookie);
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final setCookie = res.headers.value(HttpHeaders.setCookieHeader);
    if (setCookie != null) _cookie = setCookie.split(';').first;
    final text = await utf8.decoder.bind(res).join();
    Map<String, dynamic> data = {};
    if (text.trim().isNotEmpty) {
      final decoded = jsonDecode(text);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiError((data['error'] ?? '请求失败 ${res.statusCode}').toString(), res.statusCode);
    }
    return data;
  }

  Future<void> login() async {
    await request('/desk/login', method: 'POST', body: {'username': '', 'password': '', 'code': ''});
  }

  Future<ScoreData> load() async {
    final v = await Future.wait([
      request('/desk/api/days'),
      request('/desk/api/issued'),
      request('/desk/api/requests'),
      request('/desk/api/logs?limit=200'),
    ]);
    return ScoreData(v[0], _items(v[1]), _items(v[2]), _items(v[3]));
  }

  Future<void> issue(String uid, {String note = '', bool? enabled, bool noteOnly = false}) async {
    final body = <String, dynamic>{'uid': uid};
    if (note.isNotEmpty || noteOnly) body['note'] = note;
    if (enabled != null) body['enabled'] = enabled;
    if (noteOnly) body['noteOnly'] = true;
    await request('/desk/api/issued', method: 'POST', body: body);
  }

  Future<void> clearScores(String uid) => request('/desk/api/scores/clear', method: 'POST', body: {'uid': uid, 'password': ''});

  static List<Map<String, dynamic>> _items(Map<String, dynamic> data) =>
      ((data['items'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

class ScoreData {
  const ScoreData(this.days, this.issued, this.requests, this.logs);
  final Map<String, dynamic> days;
  final List<Map<String, dynamic>> issued;
  final List<Map<String, dynamic>> requests;
  final List<Map<String, dynamic>> logs;
}

/// The server currently exposes SQLite INTEGER flags. Keep all screens and
/// toggle actions on one conversion path so `1` is never mistaken for false.
bool isActiveFlag(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return const {'1', 'true', 'yes', 'on'}.contains(value.trim().toLowerCase());
  }
  return false;
}

class ScoreApp extends StatelessWidget {
  const ScoreApp({super.key});
  @override Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '熊猫麻将记分',
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: gold, secondary: green, surface: card, error: red),
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: Colors.white, elevation: 0),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: card2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: gold)),
      ),
      cardTheme: CardThemeData(color: card, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: border))),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int backendIndex = 1;
  int tab = 0;
  bool loading = true;
  String error = '';
  ScoreData? data;
  late ScoreApi api;
  Timer? timer;
  final search = TextEditingController();
  final open = <String>{};

  @override void initState() { super.initState(); _boot(); }
  @override void dispose() { timer?.cancel(); search.dispose(); super.dispose(); }

  Future<void> _boot() async {
    final prefs = await SharedPreferences.getInstance();
    backendIndex = (prefs.getInt('score_backend') ?? 1).clamp(0, 1);
    await _connect();
    timer = Timer.periodic(const Duration(seconds: 12), (_) => _refresh(silent: true));
  }

  Future<void> _connect() async {
    setState(() { loading = true; error = ''; });
    api = ScoreApi(backends[backendIndex]);
    try {
      await api.login();
      data = await api.load();
    } catch (e) {
      error = _message(e);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) setState(() => loading = true);
    try {
      data = await api.load();
      error = '';
    } on ApiError catch (e) {
      if (e.status == 401) {
        try { await api.login(); data = await api.load(); error = ''; }
        catch (again) { error = _message(again); }
      } else { error = e.message; }
    } catch (e) { error = _message(e); }
    if (mounted) setState(() => loading = false);
  }

  String _message(Object e) => e is ApiError ? e.message : '连接失败：$e';
  void _toast(String text) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }

  Future<void> _switchBackend(int value) async {
    backendIndex = value;
    final p = await SharedPreferences.getInstance();
    await p.setInt('score_backend', value);
    await _connect();
  }

  Future<void> _act(Future<void> Function() work, String ok) async {
    try { await work(); await _refresh(silent: true); _toast(ok); }
    catch (e) { _toast(_message(e)); }
  }

  @override Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('熊猫麻将记分', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
          Text('原生 Flutter 管理台', style: TextStyle(color: muted, fontSize: 11)),
        ]),
        actions: [
          PopupMenuButton<int>(
            tooltip: '切换后台',
            initialValue: backendIndex,
            onSelected: _switchBackend,
            itemBuilder: (_) => List.generate(backends.length, (i) => PopupMenuItem(value: i, child: Text(backends[i].name))),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Chip(
              avatar: Container(width: 9, height: 9, decoration: const BoxDecoration(color: green, shape: BoxShape.circle)),
              label: Text(backends[backendIndex].name),
            )),
          ),
          IconButton(onPressed: () => _refresh(), icon: const Icon(Icons.refresh_rounded)),
          const SizedBox(width: 6),
        ],
      ),
      body: loading && data == null ? const Center(child: CircularProgressIndicator()) :
        error.isNotEmpty && data == null ? _ErrorView(error: error, retry: _connect) :
        Column(children: [
          if (loading) const LinearProgressIndicator(minHeight: 2),
          if (error.isNotEmpty) Container(width: double.infinity, padding: const EdgeInsets.all(10), color: red.withValues(alpha: .15), child: Text(error, textAlign: TextAlign.center, style: const TextStyle(color: red))),
          Expanded(child: IndexedStack(index: tab, children: [
            _scorePage(), _memberPage(), _requestPage(), _logPage(),
          ])),
        ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.scoreboard_outlined), selectedIcon: Icon(Icons.scoreboard_rounded), label: '记分'),
          NavigationDestination(icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge_rounded), label: '会员'),
          NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox_rounded), label: '待处理'),
          NavigationDestination(icon: Icon(Icons.history_rounded), label: '日志'),
        ],
      ),
    );
  }

  Widget _scorePage() {
    final d = data?.days ?? {};
    final all = ScoreApi._items(d);
    final q = search.text.trim();
    final items = all.where((x) => q.isEmpty || '${x['uid']} ${x['note'] ?? ''}'.contains(q)).toList();
    final enabled = all.where((x) => isActiveFlag(x['enabled'])).length;
    final total = all.fold<num>(0, (a, x) => a + _num(x['total']));
    return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 100), children: [
      GridView.count(
        crossAxisCount: 2, childAspectRatio: 2.05, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10, mainAxisSpacing: 10,
        children: [
          _stat('今天上午', _money(d['todayMorning']), Icons.wb_sunny_outlined, _num(d['todayMorning'])),
          _stat('今天下午', _money(d['todayAfternoon']), Icons.nights_stay_outlined, _num(d['todayAfternoon'])),
          _stat('已发卡', '$enabled', Icons.credit_card_rounded, 0),
          _stat('全部净输赢', _money(total), Icons.analytics_outlined, total),
        ],
      ),
      const SizedBox(height: 14),
      TextField(controller: search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '搜索会员号或备注')),
      const SizedBox(height: 10),
      Row(children: [Text('会员记分', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)), const Spacer(), Text('${items.length} 个', style: const TextStyle(color: muted))]),
      const SizedBox(height: 6),
      if (items.isEmpty) const _Empty(icon: Icons.scoreboard_outlined, text: '还没有记分')
      else ...items.map(_scoreCard),
    ]));
  }

  Widget _stat(String label, String value, IconData icon, num amount) => Card(child: Padding(
    padding: const EdgeInsets.all(13),
    child: Row(children: [
      Container(width: 39, height: 39, decoration: BoxDecoration(color: gold.withValues(alpha: .12), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: gold, size: 21)),
      const SizedBox(width: 10),
      Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: muted, fontSize: 12)),
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: _tone(amount))),
      ])),
    ]),
  ));

  Widget _scoreCard(Map<String, dynamic> item) {
    final uid = '${item['uid'] ?? ''}';
    final expanded = open.contains(uid);
    final days = ((item['days'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final today = '${data?.days['today'] ?? ''}';
    Map<String, dynamic>? td;
    for (final x in days) { if ('${x['date']}' == today) td = x; }
    final morning = Map<String, dynamic>.from((td?['morning'] as Map?) ?? {});
    final afternoon = Map<String, dynamic>.from((td?['afternoon'] as Map?) ?? {});
    final enabled = isActiveFlag(item['enabled']);
    return Card(margin: const EdgeInsets.symmetric(vertical: 6), child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Text(uid, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)), const SizedBox(width: 8), _Badge(enabled ? '已发卡' : '未发卡', enabled)]),
          const SizedBox(height: 4), Text('${item['note']?.toString().isNotEmpty == true ? item['note'] : '无备注'} · ${item['rounds'] ?? 0} 局', style: const TextStyle(color: muted)),
        ])),
        Text(_money(item['total']), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _tone(_num(item['total'])))),
      ]),
      const SizedBox(height: 13),
      Row(children: [Expanded(child: _half('上午', morning['total'])), const SizedBox(width: 8), Expanded(child: _half('下午', afternoon['total']))]),
      const SizedBox(height: 8),
      Text('最后心跳：${_time(item['last_heartbeat'])}', style: const TextStyle(color: muted, fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, children: [
        OutlinedButton.icon(onPressed: () => setState(() => expanded ? open.remove(uid) : open.add(uid)), icon: Icon(expanded ? Icons.expand_less : Icons.expand_more), label: Text(expanded ? '收起每天' : '展开每天')),
        OutlinedButton.icon(onPressed: () => _editNote(uid, '${item['note'] ?? ''}'), icon: const Icon(Icons.edit_outlined), label: const Text('改备注')),
        OutlinedButton.icon(onPressed: () => _confirmClear(uid), icon: const Icon(Icons.delete_sweep_outlined), label: const Text('清零')),
      ]),
      if (expanded) ...[
        const Divider(height: 24),
        if (days.isEmpty) const Text('暂无每天明细', style: TextStyle(color: muted))
        else ...days.map((day) => Container(
          margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(child: Text('${day['date']}', style: const TextStyle(fontWeight: FontWeight.bold))),
            Text('上午 ${_money((day['morning'] as Map?)?['total'])}', style: TextStyle(color: _tone(_num((day['morning'] as Map?)?['total'])))),
            const SizedBox(width: 10),
            Text('下午 ${_money((day['afternoon'] as Map?)?['total'])}', style: TextStyle(color: _tone(_num((day['afternoon'] as Map?)?['total'])))),
          ]),
        )),
      ],
    ])));
  }

  Widget _half(String label, dynamic value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: card2, borderRadius: BorderRadius.circular(12)),
    child: Row(children: [Text(label, style: const TextStyle(color: muted)), const Spacer(), Text(_money(value), style: TextStyle(fontWeight: FontWeight.bold, color: _tone(_num(value))))]),
  );

  Widget _memberPage() {
    final items = data?.issued ?? [];
    return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 100), children: [
      FilledButton.icon(onPressed: _addMember, icon: const Icon(Icons.add_card_rounded), label: const Padding(padding: EdgeInsets.symmetric(vertical: 13), child: Text('发新会员卡'))),
      const SizedBox(height: 14),
      Row(children: [Text('会员卡', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)), const Spacer(), Text('${items.length} 张', style: const TextStyle(color: muted))]),
      const SizedBox(height: 6),
      if (items.isEmpty) const _Empty(icon: Icons.badge_outlined, text: '还没有发卡')
      else ...items.map((item) {
        final uid = '${item['uid']}';
        final enabled = isActiveFlag(item['enabled']);
        return Card(margin: const EdgeInsets.symmetric(vertical: 6), child: ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          leading: CircleAvatar(backgroundColor: (enabled ? green : red).withValues(alpha: .14), child: Icon(Icons.person, color: enabled ? green : red)),
          title: Row(children: [Text(uid, style: const TextStyle(fontWeight: FontWeight.bold)), const SizedBox(width: 8), _Badge(enabled ? '有效' : '停用', enabled)]),
          subtitle: Text('${item['note']?.toString().isNotEmpty == true ? item['note'] : '无备注'}\n心跳：${_time(item['last_heartbeat'])}', style: const TextStyle(color: muted)),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(onSelected: (v) {
            if (v == 'note') _editNote(uid, '${item['note'] ?? ''}');
            if (v == 'toggle') _act(() => api.issue(uid, enabled: !enabled), enabled ? '已停用 $uid' : '已恢复 $uid');
          }, itemBuilder: (_) => [
            const PopupMenuItem(value: 'note', child: Text('修改备注')),
            PopupMenuItem(value: 'toggle', child: Text(enabled ? '停用会员卡' : '恢复会员卡')),
          ]),
        ));
      }),
    ]));
  }

  Widget _requestPage() {
    final issued = data?.issued ?? [];
    final waiting = (data?.requests ?? []).where((r) {
      final uid = '${r['uid']}';
      final allowed = isActiveFlag(r['allowed']);
      final active = issued.any((x) => '${x['uid']}' == uid && isActiveFlag(x['enabled']));
      return !allowed && !active;
    }).toList();
    return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 100), children: [
      Row(children: [Text('待发卡申请', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)), const Spacer(), _Badge('${waiting.length} 条', waiting.isEmpty)]),
      const SizedBox(height: 8),
      if (waiting.isEmpty) const _Empty(icon: Icons.check_circle_outline, text: '没有待处理的号')
      else ...waiting.map((item) { final uid = '${item['uid']}'; return Card(child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)),
        title: Text(uid, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${item['hits'] ?? 1} 次 · ${_time(item['created_at'])}', style: const TextStyle(color: muted)),
        trailing: FilledButton(onPressed: () => _act(() => api.issue(uid), '已给 $uid 发卡'), child: const Text('发卡')),
      )); }),
    ]));
  }

  Widget _logPage() {
    const labels = {'login_ok':'登录成功','login_fail':'登录失败','issue':'发卡','enable':'恢复','disable':'停用','note':'改备注','clear':'清理记分','clear_denied':'清理被拒'};
    final items = data?.logs ?? [];
    return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 100), children: [
      Row(children: [Text('操作日志', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)), const Spacer(), Text('${items.length} 条', style: const TextStyle(color: muted))]),
      const SizedBox(height: 8),
      if (items.isEmpty) const _Empty(icon: Icons.history, text: '还没有日志')
      else ...items.map((x) => Card(margin: const EdgeInsets.symmetric(vertical: 5), child: ListTile(
        leading: const Icon(Icons.history_rounded, color: gold),
        title: Text(labels['${x['action']}'] ?? '${x['action']}', style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${_time(x['created_at'])} · ${x['actor'] ?? ''} · ${x['ip'] ?? ''}\n${x['target'] ?? ''} ${x['detail'] ?? ''}', style: const TextStyle(color: muted)),
        isThreeLine: true,
      ))),
    ]));
  }

  Future<void> _addMember() async {
    final uid = TextEditingController(); final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('发新会员卡'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: uid, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(labelText: '会员号', prefixIcon: Icon(Icons.numbers))),
        const SizedBox(height: 10),
        TextField(controller: note, decoration: const InputDecoration(labelText: '备注（可选）', prefixIcon: Icon(Icons.note_alt_outlined))),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('发卡'))],
    ));
    if (ok == true) {
      if (!RegExp(r'^\d+$').hasMatch(uid.text.trim())) { _toast('会员号只能输入数字'); return; }
      await _act(() => api.issue(uid.text.trim(), note: note.text.trim()), '发卡成功');
    }
  }

  Future<void> _editNote(String uid, String old) async {
    final ctl = TextEditingController(text: old);
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('修改 $uid 的备注'),
      content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: '留空可清除备注')),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存'))],
    ));
    if (ok == true) await _act(() => api.issue(uid, note: ctl.text.trim(), noteOnly: true), '备注已保存');
  }

  Future<void> _confirmClear(String uid) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      icon: const Icon(Icons.warning_amber_rounded, color: gold, size: 38),
      title: const Text('确认清零？'),
      content: Text('会员 $uid 会从零重新统计，两个后台会同步清理。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认清零'))],
    ));
    if (ok == true) await _act(() => api.clearScores(uid), '$uid 已清零');
  }

  static num _num(dynamic v) => v is num ? v : num.tryParse('$v') ?? 0;
  static String _money(dynamic v) { final n = _num(v); return n > 0 ? '+${n.toStringAsFixed(0)}' : n.toStringAsFixed(0); }
  static Color _tone(num n) => n > 0 ? green : n < 0 ? red : Colors.white;
  static String _time(dynamic v) {
    final n = int.tryParse('$v') ?? 0;
    if (n <= 0) return '无';
    final dt = DateTime.fromMillisecondsSinceEpoch(n * (n < 100000000000 ? 1000 : 1)).toLocal();
    String two(int x) => x.toString().padLeft(2, '0');
    return '${dt.month}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.good);
  final String text; final bool good;
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: (good ? green : red).withValues(alpha: .13), borderRadius: BorderRadius.circular(99), border: Border.all(color: (good ? green : red).withValues(alpha: .35))),
    child: Text(text, style: TextStyle(color: good ? green : red, fontWeight: FontWeight.bold, fontSize: 11)),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon; final String text;
  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(vertical: 70), child: Column(children: [Icon(icon, size: 55, color: muted.withValues(alpha: .5)), const SizedBox(height: 12), Text(text, style: const TextStyle(color: muted))]));
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.retry});
  final String error; final VoidCallback retry;
  @override Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.cloud_off_rounded, size: 62, color: red), const SizedBox(height: 16),
    Text(error, textAlign: TextAlign.center), const SizedBox(height: 18), FilledButton.icon(onPressed: retry, icon: const Icon(Icons.refresh), label: const Text('重新连接')),
  ])));
}
