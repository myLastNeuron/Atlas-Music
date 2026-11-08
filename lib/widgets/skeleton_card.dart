import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'app_transitions.dart';

class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    const width = 150.0;
    return Container(
      width: width,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: width,
            height: 130,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: width * 0.8,
            height: 12,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: width * 0.5,
            height: 10,
            decoration: BoxDecoration(
              color: AppColors.line,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Placeholder rows for a list page that is reloading. Home already clears its
/// rails and shows skeletons; other screens use this so a pull reads as a
/// reload instead of a spinner floating over stale rows.
class SkeletonList extends StatelessWidget {
  final int count;
  final EdgeInsetsGeometry padding;
  const SkeletonList({
    super.key,
    this.count = 10,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics:
          const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: padding,
      itemCount: count,
      itemBuilder: (_, __) => const SkeletonListItem(),
    );
  }
}

/// Pull-to-refresh that swaps [child] for [SkeletonList] until the reload
/// finishes, matching how Home shows placeholders while it loads.
class RefreshSkeleton extends StatefulWidget {
  final Future<void> Function() onRefresh;
  final Widget child;
  final int skeletonCount;
  final EdgeInsetsGeometry skeletonPadding;

  /// Optional page-shaped skeleton. Defaults to a plain list of rows.
  final Widget? skeleton;
  const RefreshSkeleton({
    super.key,
    required this.onRefresh,
    required this.child,
    this.skeletonCount = 10,
    this.skeletonPadding =
        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    this.skeleton,
  });

  @override
  State<RefreshSkeleton> createState() => _RefreshSkeletonState();
}

class _RefreshSkeletonState extends State<RefreshSkeleton> {
  bool _refreshing = false;

  Future<void> _handleRefresh() async {
    setState(() => _refreshing = true);
    try {
      await minRefresh(widget.onRefresh);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _handleRefresh,
      backgroundColor: AppColors.glass,
      color: AppColors.ink,
      child: _refreshing
          ? (widget.skeleton ??
              SkeletonList(
                count: widget.skeletonCount,
                padding: widget.skeletonPadding,
              ))
          : widget.child,
    );
  }
}

Widget _skeletonBar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.line,
        borderRadius: BorderRadius.circular(4),
      ),
    );

/// Mirrors a two-line ListTile (leading artwork, title, subtitle, trailing) so
/// swapping it in never shifts the rows' height or columns.
class SkeletonListItem extends StatelessWidget {
  const SkeletonListItem({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AppColors.line,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      title: _skeletonBar(double.infinity, 12),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: _skeletonBar(120, 10),
        ),
      ),
      trailing: _skeletonBar(40, 12),
    );
  }
}
