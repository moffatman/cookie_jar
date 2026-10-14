import 'dart:convert';

import 'package:universal_io/io.dart' show Cookie;

import '../file_storage.dart';
import '../serializable_cookie.dart';
import '../storage.dart';
import 'default.dart';

/// [PersistCookieJar] is a cookie manager which implements
/// the standard cookie policy declared in RFC.
/// [PersistCookieJar]  persists the cookies in files, if the application exit,
/// the cookies always exist unless user explicitly called [delete].
class PersistCookieJar extends DefaultCookieJar {
  /// [persistSession] is whether persisting the cookies that without
  /// "expires" or "max-age" attribute.
  /// If tbe value is false, the session cookies will be discarded.
  /// Otherwise, the session cookies will be persisted.
  ///
  /// [ignoreExpires] will determine whether to save/load expired cookies.
  ///
  /// [storage] is defaults to [FileStorage].
  PersistCookieJar({
    this.persistSession = true,
    this.cookieParser,
    bool ignoreExpires = false,
    Storage? storage,
    this.deleteHostCookiesWhenLoadFailed = true,
  })  : storage = storage ?? FileStorage(),
        super(ignoreExpires: ignoreExpires);

  /// Whether persisting cookies without "expires" or "max-age" attribute.
  final bool persistSession;

  /// Parses cookies restored from storage, including host and domain cookies.
  /// Defaults to Dart's standard Cookie parser. Supply a custom parser when
  /// saving Cookie implementations with different value validation rules.
  final Cookie Function(String)? cookieParser;
  final Storage storage;
  final bool deleteHostCookiesWhenLoadFailed;

  static const _indexKey = '.index';
  static const _domainsKey = '.domains';

  Set<String> _hostSet = {};

  bool _initialized = false;

  Future<void> forceInit() => _checkInitialized(force: true);

  Future<void> _checkInitialized({bool force = false}) async {
    if (!force && _initialized) {
      return;
    }
    await storage.init(persistSession, ignoreExpires);
    // Load domain cookies.
    String? str = await storage.read(_domainsKey);
    if (str != null && str.isNotEmpty) {
      try {
        final jsonData = (json.decode(str) as Map).cast<String, dynamic>();
        final Map<String, Map<String, Map<String, SerializableCookie>>>
            cookies = jsonData.map((domain, cookies) {
          final domainCookies = (cookies as Map)
              .cast<String, Map<dynamic, dynamic>>()
              .map<String, Map<String, SerializableCookie>>(
            (path, map) {
              final cookieForPath = map.cast<String, String>();
              final realCookies =
                  cookieForPath.map<String, SerializableCookie>((
                String cookieName,
                String cookie,
              ) {
                return MapEntry<String, SerializableCookie>(
                  cookieName,
                  SerializableCookie.fromJson(cookie, cookieParser: cookieParser),
                );
              });
              return MapEntry<String, Map<String, SerializableCookie>>(
                path,
                realCookies,
              );
            },
          );
          return MapEntry<String, Map<String, Map<String, SerializableCookie>>>(
            domain,
            domainCookies,
          );
        });
        domainCookies
          ..clear()
          ..addAll(cookies);
      } catch (e) {
        await storage.delete(_domainsKey);
      }
    }
    str = await storage.read(_indexKey);
    if ((str != null && str.isNotEmpty)) {
      try {
        final list = (json.decode(str) as List).cast<String>();
        _hostSet = Set<String>.from(list);
      } catch (e) {
        await storage.delete(_indexKey);
      }
    } else {
      _hostSet = <String>{};
    }
    _initialized = true;
  }

  @override
  Future<List<Cookie>> loadForRequest(Uri uri) async {
    await _checkInitialized();
    await _load(uri);
    return super.loadForRequest(uri);
  }

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    await _checkInitialized();
    if (cookies.isNotEmpty) {
      await super.saveFromResponse(uri, cookies);
      if (cookies.every((Cookie e) => e.domain == null)) {
        await _save(uri);
      } else {
        await _save(uri, true);
      }
    }
  }

  Map<String, Map<String, SerializableCookie>> _filter(
    Map<String, Map<String, SerializableCookie>> domain,
  ) {
    return domain.cast<String, Map<dynamic, dynamic>>().map(
      (path, cookies) {
        return MapEntry(
          path,
          Map.fromEntries(
            _filterPathEntries(
              cookies.cast<String, SerializableCookie>(),
            ),
          ),
        );
      },
    );
  }

  Iterable<MapEntry<String, SerializableCookie>> _filterPathEntries(
    Map<String, SerializableCookie> cookies,
  ) sync* {
    for (final entry in cookies.entries) {
      final cookie = entry.value;

      final isSession =
          cookie.cookie.expires == null && cookie.cookie.maxAge == null;
      if (isSession && !persistSession) continue;
      if (cookie.isExpired()) continue;

      yield entry;
    }
  }

  /// Delete cookies for specified [uri].
  /// This API will delete all cookies for the `uri.host`, it will ignored the `uri.path`.
  ///
  /// [withDomainSharedCookie] `true` will delete the domain-shared cookies.
  @override
  Future<void> delete(Uri uri, [bool withDomainSharedCookie = false]) async {
    await _checkInitialized();
    await super.delete(uri, withDomainSharedCookie);
    final host = uri.host;
    if (_hostSet.remove(host)) {
      await storage.write(_indexKey, json.encode(_hostSet.toList()));
    }
    await storage.delete(host);
    if (withDomainSharedCookie) {
      await storage.write(_domainsKey, json.encode(domainCookies));
    }
  }

  /// Delete all cookies files in the [storage] and the memory.
  @override
  Future<void> deleteAll() async {
    await _checkInitialized();
    await super.deleteAll();
    final keys = _hostSet.toList(growable: true)
      ..addAll([_indexKey, _domainsKey]);
    await storage.deleteAll(keys);
    _hostSet.clear();
  }

  Future<void> _save(Uri uri, [bool withDomainSharedCookie = false]) async {
    final host = uri.host;
    if (!_hostSet.contains(host)) {
      _hostSet.add(host);
      await storage.write(_indexKey, json.encode(_hostSet.toList()));
    }
    final cookies = hostCookies[host];
    if (cookies != null) {
      await storage.write(host, json.encode(_filter(cookies)));
    }
    if (withDomainSharedCookie) {
      final filterDomainCookies = domainCookies.map(
        (key, value) => MapEntry(key, _filter(value)),
      );
      await storage.write(_domainsKey, json.encode(filterDomainCookies));
    }
  }

  Future<void> _load(Uri uri) async {
    final host = uri.host;
    if (!_hostSet.contains(host) || hostCookies[host] != null) {
      return;
    }
    final str = await storage.read(host);
    if (str == null || str.isEmpty) {
      return;
    }
    try {
      final cookies =
          (json.decode(str) as Map).cast<String, Map<dynamic, dynamic>>();
      cookies.forEach((String path, Map<dynamic, dynamic> map) {
        map.cast<String, String>().forEach((String k, String v) {
          map[k] = SerializableCookie.fromJson(v, cookieParser: cookieParser);
        });
      });
      hostCookies[host] = cookies
          .map((k, v) => MapEntry(k, v.cast<String, SerializableCookie>()));
    } catch (e) {
      if (deleteHostCookiesWhenLoadFailed) {
        await storage.delete(host);
      }
      rethrow;
    }
  }
}
