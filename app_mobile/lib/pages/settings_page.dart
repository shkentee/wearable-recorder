import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_drive_uploader.dart';

/// SharedPreferences keys (kept in sync with device_page.dart / uploader).
const _kAutoUpload = 'wr_auto_upload';
const _kFolderKey = 'wr_drive_folder';
const _kFolderIdKey = 'wr_drive_folder_id';
const _kDefaultFolder = 'wearable-recordings';

/// App settings: which Google Drive account + folder recordings upload to,
/// and whether uploads happen automatically on disconnect.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, WrDriveUploader? uploader})
      : _uploaderOverride = uploader;

  final WrDriveUploader? _uploaderOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  String _folderName = _kDefaultFolder;
  String? _email;
  bool _autoUpload = true;
  bool _loadingEmail = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _autoUpload = prefs.getBool(_kAutoUpload) ?? true;
        _folderName = prefs.getString(_kFolderKey) ?? _kDefaultFolder;
      });
    }
    try {
      final email = await _uploader.currentEmail();
      if (mounted) setState(() => _email = email);
    } catch (_) {
      // ignore — offline / not signed in
    } finally {
      if (mounted) setState(() => _loadingEmail = false);
    }
  }

  Future<void> _switchAccount() async {
    setState(() => _busy = true);
    try {
      final email = await _uploader.chooseAccount();
      if (mounted) setState(() => _email = email);
      _snack(email == null ? 'Sign-in cancelled' : 'Signed in as $email');
    } catch (e) {
      _snack('Sign-in failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await _uploader.signOut();
      if (mounted) setState(() => _email = null);
      _snack('Signed out');
    } catch (e) {
      _snack('Sign-out failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFolder() async {
    final picked = await Navigator.push<({String id, String name})>(
      context,
      MaterialPageRoute(
        builder: (_) => _FolderPickerPage(uploader: _uploader),
      ),
    );
    if (picked == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolderIdKey, picked.id);
    await prefs.setString(_kFolderKey, picked.name);
    if (mounted) setState(() => _folderName = picked.name);
    _snack('Upload folder set to "${picked.name}"');
  }

  Future<void> _setAutoUpload(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoUpload, v);
    if (mounted) setState(() => _autoUpload = v);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Google Drive',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle),
              title: Text(_loadingEmail
                  ? 'Checking account…'
                  : (_email ?? 'Not signed in')),
              subtitle: const Text('Account recordings upload to'),
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                if (_email != null)
                  TextButton(
                    onPressed: _busy ? null : _signOut,
                    child: const Text('Sign out'),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _switchAccount,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(_email == null ? 'Sign in' : 'Switch account'),
                ),
              ],
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Upload folder'),
              subtitle: Text(_folderName),
              trailing: TextButton.icon(
                onPressed: _busy ? null : _pickFolder,
                icon: const Icon(Icons.drive_folder_upload_outlined),
                label: const Text('Change'),
              ),
              onTap: _busy ? null : _pickFolder,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Auto-upload to Drive'),
              subtitle: const Text(
                  'Upload each recording automatically when it finishes'),
              value: _autoUpload,
              onChanged: _busy ? null : _setAutoUpload,
            ),
          ],
        ),
      ),
    );
  }
}

/// A hierarchical Drive folder browser that mirrors Drive's own tree: start at
/// My Drive, tap a folder to descend, use the breadcrumb / system-back to go
/// up, and "Save here" to choose the current folder. Pops with the chosen
/// `(id, name)` record, or null if cancelled.
class _FolderPickerPage extends StatefulWidget {
  const _FolderPickerPage({required this.uploader});

  final WrDriveUploader uploader;

  @override
  State<_FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<_FolderPickerPage> {
  // Navigation stack from My Drive down to the current folder.
  final List<({String id, String name})> _stack = [
    (id: 'root', name: 'My Drive')
  ];
  List<({String id, String name})> _children = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Cross-Drive folder search (reaches "Computers"/PC-synced folders that the
  // My-Drive tree can't).
  final _searchController = TextEditingController();
  bool _searching = false;
  List<({String id, String name, List<String>? parents})> _searchResults = [];
  final Map<String, String> _pathById = {}; // result id -> location string

  ({String id, String name}) get _current => _stack.last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.uploader.listSubfolders(_current.id);
      final list = files
          .where((f) => f.id != null && f.name != null)
          .map((f) => (id: f.id!, name: f.name!))
          .toList();
      if (!mounted) return;
      setState(() {
        _children = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _enter(({String id, String name}) folder) {
    setState(() => _stack.add(folder));
    _load();
  }

  bool _goUp() {
    if (_stack.length <= 1) return false;
    setState(() => _stack.removeLast());
    _load();
    return true;
  }

  void _selectCurrent() => Navigator.pop(context, _current);

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      _clearSearch();
      return;
    }
    setState(() {
      _searching = true;
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.uploader.searchFolders(q);
      final list = files
          .where((f) => f.id != null && f.name != null)
          .map((f) => (id: f.id!, name: f.name!, parents: f.parents))
          .toList();
      if (!mounted) return;
      setState(() {
        _searchResults = list;
        _pathById.clear();
        _loading = false;
      });
      _resolvePaths(list);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _searchResults = [];
      _pathById.clear();
    });
  }

  /// Resolves each search result's full location (e.g. "My Drive › Projects"
  /// or "MyLaptop › Documents") so identically-named folders are
  /// distinguishable. Fills [_pathById] incrementally.
  Future<void> _resolvePaths(
      List<({String id, String name, List<String>? parents})> results) async {
    for (final r in results) {
      try {
        final path = await widget.uploader.folderPath(r.parents);
        if (!mounted) return;
        setState(() => _pathById[r.id] = path);
      } catch (_) {
        // Leave this one unresolved; the name is still shown.
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('New folder in "${_current.name}"'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final folder =
          await widget.uploader.createFolder(name, parentId: _current.id);
      if (!mounted) return;
      Navigator.pop(context, (id: folder.id!, name: folder.name ?? name));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Create failed: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_current.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'New folder here',
              onPressed: _busy ? null : _createFolder,
            ),
          ],
        ),
        body: Column(
          children: [
            _searchField(),
            if (!_searching) _breadcrumb(),
            const Divider(height: 1),
            Expanded(child: _searching ? _searchBody() : _body()),
          ],
        ),
        bottomNavigationBar: _searching
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _selectCurrent,
                    icon: const Icon(Icons.check),
                    label: Text('Save here: "${_current.name}"'),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search all folders (incl. Computers / PC)',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searching
              ? IconButton(
                  icon: const Icon(Icons.close), onPressed: _clearSearch)
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _searchBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: $_error'),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching folders.'),
        ),
      );
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, i) {
        final f = _searchResults[i];
        final path = _pathById[f.id];
        return ListTile(
          leading: const Icon(Icons.folder_special_outlined),
          title: Text(f.name),
          subtitle: Text(path == null ? 'resolving location…' : '📁 $path',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          isThreeLine: false,
          onTap: () =>
              Navigator.pop(context, (id: f.id, name: f.name)),
        );
      },
    );
  }

  Widget _breadcrumb() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _stack.length,
        separatorBuilder: (_, __) =>
            const Center(child: Icon(Icons.chevron_right, size: 18)),
        itemBuilder: (context, i) {
          final crumb = _stack[i];
          final isLast = i == _stack.length - 1;
          return Center(
            child: TextButton(
              onPressed: isLast
                  ? null
                  : () {
                      setState(
                          () => _stack.removeRange(i + 1, _stack.length));
                      _load();
                    },
              child: Text(crumb.name),
            ),
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_loading || _busy) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: $_error'),
        ),
      );
    }
    if (_children.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No subfolders here.\nUse "Save here" to pick this folder, '
            'or + to create a new one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _children.length,
      itemBuilder: (context, i) {
        final f = _children[i];
        return ListTile(
          leading: const Icon(Icons.folder),
          title: Text(f.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _enter(f),
        );
      },
    );
  }
}
