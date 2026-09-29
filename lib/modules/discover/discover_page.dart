import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:m3e_core/m3e_core.dart';
import '../../core/theme/app_dimens.dart';
import '../../widgets/md3_pull_to_refresh.dart';

import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/scroll_aware_app_bar.dart';
import '../../widgets/song_list_item.dart';
import '../personal_fm/personal_fm_section.dart';
import '../player/secondary_mini_player.dart';
import '../recognition/song_recognition_page.dart';
import '../search/search_page.dart';

/// 顶栏图标按钮（搜索 / 识曲）的尺寸：36 而不是 MD3 默认的 48，让两个图标之间
/// 由 24dp 收到 12dp；纵向仍保留 40dp 触达高度。
const double _kActionButtonWidth = 36.0;
const double _kActionButtonHeight = 40.0;

/// 补回按钮收窄的宽度，让最右那枚图标与屏幕边缘的距离保持不变。
const double _kActionTrailingGap = 6.0;

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  static const String _kDiscoverLastDateKey = 'discover_last_date';

  // 每日推荐区块的折叠状态（true=折叠）。SharedPreferences 存"是否折叠"。
  //
  // 发现页现在只保留私人 FM + 每日推荐两块（主题歌单/场景音乐/热门歌单/排行榜/
  // 新碟上架已迁移到搜索空白态，见 MusicExploreSections）。私人 FM 没有标题行
  // （见 [PersonalFmSection]），卡片恒定展示、无折叠把手；因此只剩每日推荐可折叠。
  static const String _kCollapsedDaily = 'discover_collapsed_daily';

  bool _isLoading = true;
  String? _error;

  bool _isDailyExpanded = true;

  /// 顶栏渐变 ScrollController：与 ScrollAwareAppBar 共享，监听滚动 offset
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initIfNeeded();
      _loadCollapseStates();
    });
  }

  /// 从 SharedPreferences 恢复每日推荐 section 的折叠状态
  Future<void> _loadCollapseStates() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _isDailyExpanded = !(prefs.getBool(_kCollapsedDaily) ?? false);
    });
  }

  /// 切换 section 展开/折叠并持久化
  Future<void> _toggleCollapse({
    required String prefKey,
    required bool currentlyExpanded,
    required ValueChanged<bool> apply,
  }) async {
    final next = !currentlyExpanded;
    setState(() => apply(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, !next);
  }

  /// 每天只自动加载一次：内存有数据且是同一天则跳过，否则拉取
  Future<void> _initIfNeeded() async {
    if (!mounted) return;
    final kugou = context.read<KugouProvider>();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lastDate = prefs.getString(_kDiscoverLastDateKey);
    final today = _todayString();
    if (kugou.hasLoadedDiscoverData && lastDate == today) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (lastDate != null && lastDate != today) {
      // 跨天：重置标志，让 _loadAllData 重新拉
      kugou.resetDiscoverLoadedFlag();
    }

    // 自动重试：首次启动时 Node.js 服务器可能尚未完全就绪
    int retryCount = 0;
    while (retryCount < 3) {
      await _loadAllData();
      if (!mounted) return;

      // 检查是否真的加载到了数据（发现页只剩每日推荐 + 私人 FM）
      if (kugou.recommendSongs.isNotEmpty ||
          kugou.personalFmSongs.isNotEmpty) {
        break; // 有数据了，退出重试
      }

      retryCount++;
      if (retryCount < 3 && mounted) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  String _todayString() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// 是否有任一发现分区数据就绪（渐进加载用）：任一就绪即退出整页转圈。
  /// 发现页只剩每日推荐 + 私人 FM 两块。
  bool get _hasAnySectionData {
    final kugou = context.read<KugouProvider>();
    return kugou.recommendSongs.isNotEmpty ||
        kugou.personalFmSongs.isNotEmpty;
  }

  Future<void> _loadAllData() async {
    if (!mounted) return; // 页面已销毁则放弃，避免访问 context 触发 null check 崩溃
    final kugou = context.read<KugouProvider>();
    final hasExistingData = kugou.hasLoadedDiscoverData;
    // 私人 FM 不跟着刷新走。它背后是流式接口（`action=play`，「给我下一批」），
    // 每次请求返回的都是不同的一批歌，而发现页的 FM 卡片直接渲染列表第一首。
    // 跟着下拉刷新就会静默换掉卡上显示的、甚至正在播的那首歌：卡片与播放器
    // 脱钩（按钮翻回 ▶、收藏指向别的歌），而且刷新不传档位参数，服务端回落到
    // normal/0，用户停在「探索」「小众」时内容还会被换成「红心」档的。
    // 所以只在手上一首都没有时补一次，之后换歌只由用户自己触发
    // （切档位 / 完整 FM 页）。
    final needsPersonalFm = kugou.personalFmSongs.isEmpty;
    // 已有数据时直接展示，后台静默刷新
    if (!hasExistingData) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      // 渐进加载：请求并行发起，每个分区完成后立即刷新一次。
      // 发现页只保留每日推荐 + 私人 FM 两块；主题歌单/场景音乐/热门歌单/
      // 排行榜/新碟上架已迁到搜索空白态（MusicExploreSections 按需拉取）。
      final reqs = <Future<void>>[
        kugou.getRecommendDaily(forceRefresh: hasExistingData),
        // 这里 forceRefresh 恒为 true 不是笔误：列表为空才会走到这一句，而空列表
        // 也会盖上新鲜时间戳（上一次请求成功但返回了空），不绕开 5 分钟 TTL 的话
        // 卡片会空着却「新鲜」，下拉也补不回来。
        if (needsPersonalFm) kugou.getPersonalFm(forceRefresh: true),
      ];
      for (final f in reqs) {
        unawaited(f.then((_) {
          if (mounted) setState(() {});
        }).catchError((Object _) {
          // 单个分区失败不阻塞其它分区；错误由最终判定/分区自身兜底
          if (mounted) setState(() {});
        }));
      }
      await Future.wait(reqs);

      // 只有确实加载到数据时才标记为已加载
      final hasAnyData =
          kugou.recommendSongs.isNotEmpty || kugou.personalFmSongs.isNotEmpty;
      if (!mounted) return;
      if (hasAnyData) {
        kugou.markDiscoverLoaded();
        // 任何一次加载成功都把日期标记为今天
        final prefs = await SharedPreferences.getInstance();
        if (!mounted) return;
        await prefs.setString(_kDiscoverLastDateKey, _todayString());
      }
    } catch (e) {
      if (!mounted) return;
      _error = e.toString();
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: ScrollAwareAppBar(
        title: '发现',
        tabId: 'discover',
        scrollController: _scrollController,
        // 公开版偏好：无壁纸时顶部恒为不透明 surface（文字区稳定）；
        // 有壁纸时顶栏完全透明，壁纸透出与页面主体透明度上下一致
        opaque: true,
        titleTrailing: _buildGreetingPill(colorScheme),
        actions: [
          _buildActionIcon(
            icon: Icons.search,
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
          Padding(
            padding: const EdgeInsets.only(right: _kActionTrailingGap),
            child: _buildActionIcon(
              icon: Icons.mic_outlined,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SongRecognitionPage()),
              ),
            ),
          ),
        ],
      ),
      body: Md3PullToRefresh(
        onRefresh: _loadAllData,
        // 渐进加载：任一分区数据就绪即退出整页转圈，先显示已获取的分区；
        // 未就绪分区由各自 Selector 在数据到达时自动补出（空数据返回占位）。
        child: _isLoading && !_hasAnySectionData
            ? const Center(child: M3ELoadingIndicator())
            : _error != null && !_hasAnySectionData
            ? _buildError(colorScheme)
            : CustomScrollView(
                controller: _scrollController,
                slivers: [
                  _buildPersonalFmSection(),
                  _buildDailySection(colorScheme),
                  const SliverToBoxAdapter(child: SizedBox(height: 80)),
                ],
              ),
      ),
    );
  }

  String _getGreeting() {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  Widget _buildError(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const Gap(AppSpacing.md),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const Gap(AppSpacing.sm),
            Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(AppSpacing.lg),
            FilledButton.tonal(
              onPressed: _loadAllData,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 三个参数缺一不可：`constraints` 定按钮尺寸，`padding` 让 24dp 的图标塞得进
  /// 36dp 的框，`visualDensity` 改的是 MD3 垫在外面那层 48dp 的布局尺寸——不动它
  /// 按钮画小了、占位照旧。
  Widget _buildActionIcon({
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      visualDensity: const VisualDensity(horizontal: -3, vertical: -2),
      constraints: const BoxConstraints.tightFor(
        width: _kActionButtonWidth,
        height: _kActionButtonHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  /// 问候胶囊，紧跟在顶栏标题右边。宽度贴着文字长短变，上限由标题区剩下的宽度
  /// 决定（见 [ScrollAwareAppBar.titleTrailing]），顶格时由 ellipsis 收尾。
  Widget _buildGreetingPill(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      decoration: ShapeDecoration(
        color: cs.primaryContainer,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Selector<KugouProvider, String?>(
              selector: (_, kugou) =>
                  kugou.isLoggedIn ? kugou.userInfo?.nickname : null,
              builder: (context, nickname, _) {
                final greeting = _getGreeting();
                return Text(
                  nickname == null || nickname.isEmpty
                      ? greeting
                      : '$greeting，$nickname',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelLarge?.copyWith(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
          const Gap(AppSpacing.xs),
          Icon(Icons.music_note, size: 16, color: cs.onPrimaryContainer),
        ],
      ),
    );
  }

  Widget _buildPersonalFmSection() {
    return const SliverToBoxAdapter(child: PersonalFmSection());
  }

  /// 每日推荐：竖排前四首。
  ///
  /// 原来是 76dp 高的横滑条，是全页最矮的区块——语义最重的内容拿到了最轻的
  /// 视觉权重。而且卡内布局是「封面在左、文字在右」的列表项形态，被硬塞进横滑
  /// 列表：横滑方向和卡内阅读方向一致，眼睛不知道该往哪走。
  ///
  /// 改成竖排后它同时打断了「五连横滑」的单一节奏，并且复用 [SongListItem]，
  /// 顺带拿到「正在播」高亮、收藏、更多菜单（含 MV）——原来的 _DailySongCard 一个都没有。
  /// 全部 30 首仍在标题右侧的 `›` 里。
  Widget _buildDailySection(ColorScheme cs) {
    return Selector<KugouProvider, List<KugouSongDetail>>(
      selector: (_, kugou) => kugou.recommendSongs,
      builder: (context, songs, _) {
        if (songs.isEmpty) return const SliverToBoxAdapter(child: SizedBox());
        final all = songs.map((e) => e.toSong()).toList();
        final top = all.take(4).toList();
        return SliverToBoxAdapter(
          child: _CollapsibleSection(
            title: '每日推荐',
            isExpanded: _isDailyExpanded,
            onToggle: () => _toggleCollapse(
              prefKey: _kCollapsedDaily,
              currentlyExpanded: _isDailyExpanded,
              apply: (v) => _isDailyExpanded = v,
            ),
            trailing: IconButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const _DailyRecommendDetailPage(),
                  ),
                );
              },
              icon: const Icon(Icons.chevron_right),
            ),
            child: Padding(
              // SongListItem 自带 horizontal 10 的内边距，补 6 凑成
              // 与其他区块一致的 16dp 页边距。
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (var i = 0; i < top.length; i++)
                    SongListItem(
                      song: top[i],
                      showDuration: false,
                      // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                      trailingActions: SongTrailingActions.favoriteOnly,
                      onTap: () => context
                          .read<PlayerProvider>()
                          .playOnlinePlaylist(all, i),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DailyRecommendDetailPage extends StatefulWidget {
  const _DailyRecommendDetailPage();

  @override
  State<_DailyRecommendDetailPage> createState() =>
      _DailyRecommendDetailPageState();
}

class _DailyRecommendDetailPageState extends State<_DailyRecommendDetailPage> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<KugouProvider>().getRecommendDaily();
      if (mounted) setState(() => _isLoading = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('每日推荐')),
      body: SecondaryMiniPlayerHost(
        child: _isLoading
          ? const Center(child: M3ELoadingIndicator())
          : Selector<KugouProvider, List<KugouSongDetail>>(
              selector: (_, kugou) => kugou.recommendSongs,
              builder: (context, recommendSongs, _) {
                final songs = recommendSongs.map((e) => e.toSong()).toList();
                if (songs.isEmpty) return const Center(child: Text('暂无数据'));
                return Column(
                  children: [
                    // 播放全部：把当日的 30 首当一张歌单从头连播。
                    // 形态与专辑/歌单/听书详情页的主行动按钮一致
                    // （FilledButton.icon + play_arrow）。
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.lg,
                        AppSpacing.sm,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => context
                              .read<PlayerProvider>()
                              .playOnlinePlaylist(songs, 0),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放全部'),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.sm,
                          AppSpacing.lg,
                          AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
                        ),
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return SongListItem(
                            song: song,
                            // 每日推荐：右侧仅收藏按钮（见改版计划二）。
                            trailingActions: SongTrailingActions.favoriteOnly,
                            onTap: () {
                              context.read<PlayerProvider>().playOnlinePlaylist(
                                songs,
                                index,
                              );
                            },
                            onMoreTap: () {},
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
      ),
    );
  }
}

/// 可折叠 section 容器：
/// - 标题行左侧可点击区域（标题 + chevron 图标）触发 onToggle 折叠/展开
/// - 标题行右侧可放额外 widget（如"查看更多"按钮）
/// - 内容用 AnimatedCrossFade 在展示态和零高度态间平滑过渡
class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    this.trailing,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: AppRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: tt.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Gap(AppSpacing.xs),
                        AnimatedRotation(
                          turns: isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: isExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          sizeCurve: Curves.easeInOut,
          firstChild: child,
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
