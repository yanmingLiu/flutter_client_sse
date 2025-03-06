library flutter_client_sse;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:http/http.dart' as http;

part 'sse_event_model.dart';

/// SSE 客户端
class SSEClient {
  static const Duration retryDelay = Duration(seconds: 5); // 重试间隔

  /// 处理 SSE 连接的重试逻辑
  static void _retryConnection({
    required SSERequestType method,
    required String url,
    required Map<String, String> headers,
    required StreamController<SSEModel> streamController,
    required int maxRetries,
    required int retriesLeft,
    Map<String, dynamic>? body,
  }) {
    if (retriesLeft <= 0) {
      final errorMsg = '⚠️ 已达到最大重试次数 ($maxRetries)，停止重试';
      print(errorMsg);
      if (!streamController.isClosed) {
        streamController.addError(Exception(errorMsg));
        streamController.close();
      }
      return;
    }

    print('🔄 SSE 重新连接中... (剩余重试次数: $retriesLeft)');

    Future.delayed(retryDelay, () {
      if (!streamController.isClosed) {
        subscribeToSSE(
          method: method,
          url: url,
          headers: headers,
          body: body,
          oldStreamController: streamController,
          maxRetries: maxRetries,
          retriesLeft: retriesLeft - 1,
        );
      }
    });
  }

  /// 处理 SSE 连接错误
  static void _handleError({
    required dynamic error,
    required SSERequestType method,
    required String url,
    required Map<String, String> headers,
    required StreamController<SSEModel> streamController,
    required int maxRetries,
    required int retriesLeft,
    Map<String, dynamic>? body,
  }) {
    print('❌ SSE 连接错误: $error');
    if (!streamController.isClosed) {
      streamController.addError(error);
      _retryConnection(
        method: method,
        url: url,
        headers: headers,
        streamController: streamController,
        maxRetries: maxRetries,
        retriesLeft: retriesLeft,
        body: body,
      );
    }
  }

  /// 订阅 SSE 事件
  static Stream<SSEModel> subscribeToSSE({
    required SSERequestType method,
    required String url,
    required Map<String, String> headers,
    StreamController<SSEModel>? oldStreamController,
    Map<String, dynamic>? body,
    required int maxRetries,
    int? retriesLeft,
  }) {
    final StreamController<SSEModel> streamController = oldStreamController ?? StreamController();
    final http.Client client = http.Client(); // 独立的 HTTP 客户端

    final lineRegex = RegExp(r'^([^:]*)(?::)?(?: )?(.*)?$');

    // 初始化剩余重试次数
    retriesLeft ??= maxRetries;

    print("📡 连接 SSE: $url");

    try {
      final request = http.Request(
        method == SSERequestType.GET ? "GET" : "POST",
        Uri.parse(url),
      )..headers.addAll(headers);

      if (body != null) {
        request.body = jsonEncode(body);
      }

      client.send(request).then((response) {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _handleError(
            error: 'HTTP ${response.statusCode}',
            method: method,
            url: url,
            headers: headers,
            streamController: streamController,
            maxRetries: maxRetries,
            retriesLeft: retriesLeft!,
            body: body,
          );
          return;
        }

        SSEModel currentSSEModel = SSEModel(data: '', id: '', event: '');

        response.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
              (dataLine) {
                if (dataLine.isEmpty) {
                  if (currentSSEModel.data != null && currentSSEModel.data!.isNotEmpty) {
                    streamController.add(currentSSEModel);
                  }
                  currentSSEModel = SSEModel(data: '', id: '', event: '');
                  return;
                }

                final match = lineRegex.firstMatch(dataLine);
                if (match == null) return;

                final field = match.group(1);
                final value = match.group(2) ?? '';

                switch (field) {
                  case 'event':
                    currentSSEModel.event = value;
                    break;
                  case 'data':
                    currentSSEModel.data = (currentSSEModel.data ?? '') + value + '\n';
                    break;
                  case 'id':
                    currentSSEModel.id = value;
                    break;
                  default:
                    print('⚠️ 未知字段: $dataLine');
                }
              },
              onError: (e) => _handleError(
                error: e,
                method: method,
                url: url,
                headers: headers,
                streamController: streamController,
                maxRetries: maxRetries,
                retriesLeft: retriesLeft!,
                body: body,
              ),
              onDone: () {
                print('🔌 SSE 连接关闭');
                if (!streamController.isClosed) {
                  _retryConnection(
                    method: method,
                    url: url,
                    headers: headers,
                    streamController: streamController,
                    maxRetries: maxRetries,
                    retriesLeft: retriesLeft!,
                    body: body,
                  );
                }
              },
              cancelOnError: true,
            );
      }).catchError(
        (e) {
          _handleError(
            error: e,
            method: method,
            url: url,
            headers: headers,
            streamController: streamController,
            maxRetries: maxRetries,
            retriesLeft: retriesLeft!,
            body: body,
          );
        },
      );
    } catch (e) {
      _handleError(
        error: e,
        method: method,
        url: url,
        headers: headers,
        streamController: streamController,
        maxRetries: maxRetries,
        retriesLeft: retriesLeft,
        body: body,
      );
    }

    streamController.onCancel = () {
      client.close();
      print("🛑 SSE 连接已关闭");
    };

    return streamController.stream;
  }
}
