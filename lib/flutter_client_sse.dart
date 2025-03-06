library flutter_client_sse;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:http/http.dart' as http;

part 'sse_event_model.dart';

/// SSE 客户端
class SSEClient {
  static const int maxRetries = 5; // 最大重试次数

  /// 处理 SSE 连接的重试逻辑
  static void _retryConnection({
    required SSERequestType method,
    required String url,
    required Map<String, String> headers,
    required StreamController<SSEModel> streamController,
    Map<String, dynamic>? body,
    int retryCount = 0,
  }) {
    if (retryCount >= maxRetries) {
      print('⚠️ 已达到最大重试次数 ($maxRetries)，停止重试');
      if (!streamController.isClosed) {
        streamController.addError(Exception('已达到最大重试次数 ($maxRetries)，停止重试'));
        streamController.close();
      }
      return;
    }

    print('🔄 SSE 重新连接中... (第 ${retryCount + 1} 次)');

    Future.delayed(Duration(seconds: 5), () {
      if (!streamController.isClosed) {
        subscribeToSSE(
          method: method,
          url: url,
          headers: headers,
          body: body,
          oldStreamController: streamController,
          retryCount: retryCount + 1,
        );
      }
    });
  }

  /// 订阅 SSE 事件
  static Stream<SSEModel> subscribeToSSE({
    required SSERequestType method,
    required String url,
    required Map<String, String> headers,
    StreamController<SSEModel>? oldStreamController,
    Map<String, dynamic>? body,
    int retryCount = 0,
  }) {
    final StreamController<SSEModel> streamController = oldStreamController ?? StreamController();
    final http.Client client = http.Client(); // 每个连接独立的 Client
    final lineRegex = RegExp(r'^([^:]*)(?::)?(?: )?(.*)?$');
    SSEModel currentSSEModel = SSEModel(data: '', id: '', event: '');

    print("📡 正在连接 SSE: $url");

    try {
      final request = http.Request(
        method == SSERequestType.GET ? "GET" : "POST",
        Uri.parse(url),
      );

      request.headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);

      client.send(request).then((response) {
        // 检查 HTTP 状态码
        if (response.statusCode < 200 || response.statusCode >= 300) {
          print('❌ HTTP 错误: ${response.statusCode}');
          streamController.addError(Exception('HTTP ${response.statusCode}'));
          _retryConnection(
            method: method,
            url: url,
            headers: headers,
            streamController: streamController,
            body: body,
            retryCount: retryCount,
          );
          return;
        }

        response.stream.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (dataLine) {
            if (dataLine.isEmpty) {
              streamController.add(currentSSEModel);
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
              case 'retry':
                break;
              default:
                print('⚠️ 未知字段: $dataLine');
            }
          },
          onError: (e) {
            print('❌ SSE 连接错误: $e');
            if (!streamController.isClosed) {
              streamController.addError(e);
              _retryConnection(
                method: method,
                url: url,
                headers: headers,
                streamController: streamController,
                body: body,
                retryCount: retryCount,
              );
            }
          },
          onDone: () {
            print('🔌 SSE 连接关闭');
            if (!streamController.isClosed) {
              _retryConnection(
                method: method,
                url: url,
                headers: headers,
                streamController: streamController,
                body: body,
                retryCount: retryCount,
              );
            }
          },
          cancelOnError: true,
        );
      }).catchError((e) {
        print('❌ HTTP 请求失败: $e');
        if (!streamController.isClosed) {
          streamController.addError(e);
          _retryConnection(
            method: method,
            url: url,
            headers: headers,
            streamController: streamController,
            body: body,
            retryCount: retryCount,
          );
        }
      });
    } catch (e) {
      print('❌ 发生异常: $e');
      if (!streamController.isClosed) {
        streamController.addError(e);
        _retryConnection(
          method: method,
          url: url,
          headers: headers,
          streamController: streamController,
          body: body,
          retryCount: retryCount,
        );
      }
    }

    // 监听流控制器关闭，终止 Client 和连接
    streamController.onCancel = () {
      client.close();
      print("🛑 SSE 连接已关闭");
    };

    return streamController.stream;
  }
}
