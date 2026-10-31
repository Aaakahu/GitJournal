/*
 * SPDX-FileCopyrightText: 2019-2021 Vishesh Handa <me@vhanda.in>
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import 'package:flutter/material.dart';

import 'package:gitjournal/widgets/delayed_loading_gate.dart';

class FutureBuilderWithProgress<T> extends StatelessWidget {
  final Future<T> future;

  const FutureBuilderWithProgress({
    super.key,
    required this.future,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      builder: (context, AsyncSnapshot<T> snapshot) {
        if (snapshot.hasData) {
          return snapshot.data as Widget;
        }
        // 本地读取毫秒级：300ms 内完成就不闪指示器，超时才给出等待反馈。
        return DelayedLoadingGate(
          loading: true,
          builder: (context, showLoading) => showLoading
              ? const Center(child: CircularProgressIndicator())
              : const SizedBox(),
        );
      },
      future: future,
    );
  }
}
