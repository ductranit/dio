import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../adapter.dart';
import '../options.dart';
import '../dio_error.dart';
import '../redirect_record.dart';

typedef OnHttpClientCreate = HttpClient? Function(HttpClient client);

HttpClientAdapter createAdapter() => DefaultHttpClientAdapter();

/// The default HttpClientAdapter for Dio.
class DefaultHttpClientAdapter implements HttpClientAdapter {
  /// [Dio] will create HttpClient when it is needed.
  /// If [onHttpClientCreate] is provided, [Dio] will call
  /// it when a HttpClient created.
  OnHttpClientCreate? onHttpClientCreate;

  HttpClient? _defaultHttpClient;

  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future? cancelFuture,
  ) async {
    if (_closed) {
      throw Exception(
          "Can't establish connection after [HttpClientAdapter] closed!");
    }
    var _httpClient = _configHttpClient(cancelFuture, options.connectTimeout);
    var reqFuture = _httpClient.openUrl(options.method, options.uri);

    void _throwConnectingTimeout() {
      throw DioError(
        requestOptions: options,
        error: 'Connecting timed out [${options.connectTimeout}ms]',
        type: DioErrorType.connectTimeout,
      );
    }

    late HttpClientRequest request;
    try {
      request = await reqFuture;
      if (options.connectTimeout > 0) {
        request = await reqFuture
            .timeout(Duration(milliseconds: options.connectTimeout));
      } else {
        request = await reqFuture;
      }

      //Set Headers
      options.headers.forEach((k, v) {
        if (v != null) request.headers.set(k, '$v');
      });
    } on SocketException catch (e) {
      if (e.message.contains('timed out')) {
        _throwConnectingTimeout();
      }
      rethrow;
    } on TimeoutException {
      _throwConnectingTimeout();
    }

    request.followRedirects = options.followRedirects;
    request.maxRedirects = options.maxRedirects;

    if (requestStream != null) {
      // Transform the request data
      var future = request.addStream(requestStream);
      if (options.sendTimeout > 0) {
        future = future.timeout(Duration(milliseconds: options.sendTimeout));
      }
      try {
        await future;
      } on TimeoutException {
        request.abort();
        throw DioError(
          requestOptions: options,
          error: 'Sending timeout[${options.sendTimeout}ms]',
          type: DioErrorType.sendTimeout,
        );
      }
    }

    // [receiveTimeout] represents a timeout during data transfer! That is to say the
    // client has connected to the server.
    int receiveStart = DateTime.now().millisecondsSinceEpoch;
    var future = request.close();
    if (options.receiveTimeout > 0) {
      future = future.timeout(Duration(milliseconds: options.receiveTimeout));
    }
    late HttpClientResponse responseStream;
    try {
      responseStream = await future;
    } on TimeoutException {
      throw DioError(
        requestOptions: options,
        error: 'Receiving data timeout[${options.receiveTimeout}ms]',
        type: DioErrorType.receiveTimeout,
      );
    }

    var stream =
        responseStream.transform<Uint8List>(StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        if (options.receiveTimeout > 0 &&
            DateTime.now().millisecondsSinceEpoch - receiveStart >
                options.receiveTimeout) {
          sink.addError(
            DioError(
              requestOptions: options,
              error: 'Receiving data timeout[${options.receiveTimeout}ms]',
              type: DioErrorType.receiveTimeout,
            ),
          );
          responseStream.detachSocket().then((socket) => socket.destroy());
        } else {
          sink.add(Uint8List.fromList(data));
        }
      },
    ));

    var headers = <String, List<String>>{};
    responseStream.headers.forEach((key, values) {
      headers[key] = values;
    });
    return ResponseBody(
      stream,
      responseStream.statusCode,
      headers: headers,
      isRedirect:
          responseStream.isRedirect || responseStream.redirects.isNotEmpty,
      redirects: responseStream.redirects
          .map((e) => RedirectRecord(e.statusCode, e.method, e.location))
          .toList(),
      statusMessage: responseStream.reasonPhrase,
    );
  }

  HttpClient _configHttpClient(Future? cancelFuture, int connectionTimeout) {
    var _connectionTimeout = connectionTimeout > 0
        ? Duration(milliseconds: connectionTimeout)
        : null;

    if (cancelFuture != null) {
      var _httpClient = HttpClient();
      _httpClient.userAgent = null;
      if (onHttpClientCreate != null) {
        //user can return a HttpClient instance
        _httpClient = onHttpClientCreate!(_httpClient) ?? _httpClient;
      }
      _httpClient.idleTimeout = Duration(seconds: 0);
      cancelFuture.whenComplete(() {
        Future.delayed(Duration(seconds: 0)).then((e) {
          try {
            _httpClient.close(force: true);
          } catch (e) {
            //...
          }
        });
      });
      return _httpClient..connectionTimeout = _connectionTimeout;
    }
    if (_defaultHttpClient == null) {
      _defaultHttpClient = HttpClient();
      _defaultHttpClient!.idleTimeout = Duration(seconds: 3);
      if (onHttpClientCreate != null) {
        //user can return a HttpClient instance
        _defaultHttpClient =
            onHttpClientCreate!(_defaultHttpClient!) ?? _defaultHttpClient;
      }
      _defaultHttpClient!.connectionTimeout = _connectionTimeout;
    }
    return _defaultHttpClient!..connectionTimeout = _connectionTimeout;
  }

  @override
  void close({bool force = false}) {
    _closed = _closed;
    _defaultHttpClient?.close(force: force);
  }
}
