import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Base class for failures that are shown to the user. [message] is always
/// human-readable; the raw cause stays in [cause] for logs.
class AppException implements Exception {
  final String message;
  final Object? cause;

  const AppException(this.message, {this.cause});

  /// Whether retrying the same request is likely to help.
  bool get retryable => true;

  @override
  String toString() => message;
}

/// Device is offline or the host is unreachable.
class OfflineException extends AppException {
  const OfflineException({Object? cause})
    : super('No internet connection', cause: cause);
}

/// The server didn't answer in time.
class TimeoutAppException extends AppException {
  const TimeoutAppException({Object? cause})
    : super('The server took too long to respond', cause: cause);
}

/// The server answered with an error status.
class ServerException extends AppException {
  final int statusCode;

  ServerException(this.statusCode, {String? message, Object? cause})
    : super(
        message ??
            (statusCode == 429
                ? 'Too many requests — please wait a moment'
                : statusCode >= 500
                ? 'The server is busy right now'
                : 'Request failed (HTTP $statusCode)'),
        cause: cause,
      );

  @override
  bool get retryable => statusCode == 429 || statusCode >= 500;
}

/// The server replied but the payload wasn't what we expected.
class BadResponseException extends AppException {
  const BadResponseException({String? message, Object? cause})
    : super(message ?? 'Unexpected response from the server', cause: cause);

  @override
  bool get retryable => false;
}

/// Converts low-level transport errors into an [AppException]. Anything
/// already an [AppException] passes through unchanged.
AppException toAppException(Object error, {String? fallback}) {
  if (error is AppException) return error;
  if (error is SocketException) return OfflineException(cause: error);
  if (error is TimeoutException) return TimeoutAppException(cause: error);
  if (error is http.ClientException) {
    final m = error.message.toLowerCase();
    if (m.contains('failed host lookup') ||
        m.contains('connection') ||
        m.contains('network')) {
      return OfflineException(cause: error);
    }
    return AppException(fallback ?? 'Network error', cause: error);
  }
  if (error is FormatException || error is TypeError) {
    return BadResponseException(cause: error);
  }
  return AppException(fallback ?? 'Something went wrong', cause: error);
}

/// Runs [body], logging and translating any failure into an [AppException].
Future<T> guarded<T>(
  String what,
  Future<T> Function() body, {
  String? fallback,
}) async {
  try {
    return await body();
    // Deliberately broad: this is the boundary where TypeErrors from
    // unexpected JSON shapes become user-facing messages too.
    // ignore: avoid_catches_without_on_clauses
  } catch (e, s) {
    final mapped = toAppException(e, fallback: fallback);
    logError(what, e, s);
    throw mapped;
  }
}

/// Debug-only logging for swallowed or translated errors. Release builds
/// stay silent; hook a crash reporter here when there is one.
void logError(String what, Object error, [StackTrace? stack]) {
  if (!kDebugMode) return;
  debugPrint('[zamosaride] $what: $error');
  if (stack != null && error is! AppException) {
    debugPrint(stack.toString().split('\n').take(6).join('\n'));
  }
}
