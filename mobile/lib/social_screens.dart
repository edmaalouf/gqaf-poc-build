import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';

import 'app.dart';
import 'models.dart';
import 'profile_screens.dart';

String localTime(DateTime time) =>
    DateFormat.yMMMd().add_jm().format(time.toLocal());

Future<bool> confirm(
  BuildContext context,
  String title,
  String detail,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> safetyAction(
  BuildContext context,
  AppController controller,
  int id,
  String name,
  String kind,
) async {
  String? reason;
  if (kind == 'block') {
    if (!await confirm(
      context,
      'Block $name?',
      'You will no longer see or message each other.',
      'Block',
    )) {
      return false;
    }
  } else {
    final input = TextEditingController();
    reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Report $name'),
        content: TextField(
          controller: input,
          maxLength: 1000,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'What happened?',
            helperText:
                'At least 5 characters. Reporting removes this person from view.',
            helperMaxLines: 2,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('Submit report'),
          ),
        ],
      ),
    );
    input.dispose();
    if (reason == null) return false;
    if (reason.length < 5) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please provide at least 5 characters.'),
          ),
        );
      }
      return false;
    }
  }
  if (!context.mounted) return false;
  return runAction(context, () async {
    await controller.api.request(
      'POST',
      '/api/v1/safety/$id',
      body: {'kind': kind, 'reason': ?reason},
    );
  }, success: kind == 'block' ? 'Person blocked.' : 'Report submitted.');
}

class IntroductionsScreen extends StatefulWidget {
  const IntroductionsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<IntroductionsScreen> createState() => _IntroductionsScreenState();
}

class _IntroductionsScreenState extends State<IntroductionsScreen> {
  late Future<WeeklyIntroductions> data;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    data = widget.controller.api.introductions();
  }

  void reload() => setState(() {
    data = widget.controller.api.introductions();
  });
  Future<void> react(Introduction person, String kind) async {
    if (kind == 'pass' &&
        !await confirm(
          context,
          'Pass on ${person.name}?',
          'Passing is permanent in this prototype.',
          'Pass',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    final ok = await runAction(
      context,
      () async {
        await widget.controller.api.request(
          'POST',
          '/api/v1/matches/${person.id}/reaction',
          body: {'kind': kind},
        );
      },
      success: kind == 'like'
          ? 'Like saved. A conversation opens if interest is mutual.'
          : 'Pass saved.',
    );
    if (mounted) {
      setState(() => busy = false);
      if (ok) reload();
    }
  }

  Future<void> safety(Introduction person, String kind) async {
    setState(() => busy = true);
    final ok = await safetyAction(
      context,
      widget.controller,
      person.id,
      person.name,
      kind,
    );
    if (mounted) {
      setState(() => busy = false);
      if (ok) reload();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<WeeklyIntroductions>(
    future: data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return PageBody(
          title: 'Your introductions',
          subtitle: 'Unable to load introductions.',
          children: [
            Text(errorMessage(snapshot.error!)),
            TextButton(onPressed: reload, child: const Text('Try again')),
          ],
        );
      }
      if (snapshot.connectionState != ConnectionState.done ||
          !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final result = snapshot.data!;
      return RefreshIndicator(
        onRefresh: () async {
          await runAction(context, () async {
            reload();
            await data;
          });
        },
        child: PageBody(
          title: 'Your introductions',
          subtitle:
              'Up to three people who meet your mutual preferences. You can message after you both choose Like.',
          children: [
            if (widget.controller.account?.matchingPaused == true)
              const Panel(
                child: Text(
                  'Your profile is paused. Introductions and conversations are hidden until you resume in Settings.',
                ),
              ),
            if (result.cycle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text('Week of ${localTime(result.cycle!)}'),
              ),
            if (result.introductions.isEmpty)
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.cycle == null
                          ? 'No introductions yet'
                          : 'No introductions this week',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      result.cycle == null
                          ? 'The first matching cycle has not run yet.'
                          : 'There are no available introductions this week. We do not add replacements midweek.',
                    ),
                  ],
                ),
              ),
            for (final group in [
              (title: '', people: result.introductions),
              if (result.invitations.isNotEmpty)
                (title: 'Private invitations', people: result.invitations),
            ]) ...[
              if (group.title.isNotEmpty) ...[
                Text(
                  group.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'These people liked you this week. Invitations are separate from your weekly introductions and expire with this cycle.',
                ),
                const SizedBox(height: 16),
              ],
              for (final person in group.people)
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 280,
                        child: ProfilePhoto(
                          controller: widget.controller,
                          userId: person.id,
                          name: '${person.name}’s approved photo',
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${person.name}, ${person.age}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Text(
                        '${person.distanceLabel} · ${label(person.intention)}',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${person.score.round()}% compatible',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        person.sharedInterests.isEmpty
                            ? 'No shared interests listed.'
                            : 'Shared interests: ${person.sharedInterests.join(', ')}',
                      ),
                      const SizedBox(height: 8),
                      Text(person.bio),
                      const SizedBox(height: 8),
                      Text(
                        person.similarities.isEmpty
                            ? 'Explore what makes your perspectives different.'
                            : 'You answered similarly in ${person.similarities.join(' and ').toLowerCase()}.',
                      ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Compatibility breakdown'),
                        children: [
                          for (final entry in person.breakdown.entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Row(
                                children: [
                                  Expanded(flex: 4, child: Text(entry.key)),
                                  Expanded(
                                    flex: 3,
                                    child: LinearProgressIndicator(
                                      value: entry.value / 100,
                                      semanticsLabel:
                                          '${entry.key} compatibility',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text('${entry.value.round()}%'),
                                ],
                              ),
                            ),
                          const Text('Individual answers are private.'),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: busy || person.reaction != null
                                ? null
                                : () => react(person, 'pass'),
                            child: const Text('Pass'),
                          ),
                          FilledButton(
                            onPressed: busy || person.reaction != null
                                ? null
                                : () => react(person, 'like'),
                            child: Text(
                              person.reaction == 'like' ? 'Liked' : 'Like',
                            ),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => safety(person, 'report'),
                            child: const Text('Report'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => safety(person, 'block'),
                            child: const Text('Block'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
            const Text(
              'Compatibility is an estimate, not a guarantee of relationship success.',
            ),
          ],
        ),
      );
    },
  );
}

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  late Future<List<Conversation>> data;
  @override
  void initState() {
    super.initState();
    data = widget.controller.api.conversations();
  }

  void reload() => setState(() {
    data = widget.controller.api.conversations();
  });
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Conversation>>(
    future: data,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return PageBody(
          title: 'Conversations',
          subtitle: 'Unable to load conversations.',
          children: [
            Text(errorMessage(snapshot.error!)),
            TextButton(onPressed: reload, child: const Text('Try again')),
          ],
        );
      }
      if (snapshot.connectionState != ConnectionState.done ||
          !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final conversations = snapshot.data!;
      return RefreshIndicator(
        onRefresh: () async {
          await runAction(context, () async {
            reload();
            await data;
          });
        },
        child: PageBody(
          title: 'Conversations',
          subtitle: 'Conversations open when interest is mutual.',
          children: [
            if (conversations.isEmpty)
              const Panel(
                child: Text(
                  'No conversations yet. When you both like each other, your conversation appears here.',
                ),
              ),
            for (final conversation in conversations)
              Panel(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(conversation.name),
                  subtitle: Text(
                    conversation.unread > 0
                        ? '${conversation.unread} unread'
                        : 'Open conversation',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await openPage(
                      context,
                      ChatScreen(
                        controller: widget.controller,
                        conversation: conversation,
                      ),
                    );
                    if (mounted) reload();
                  },
                ),
              ),
          ],
        ),
      );
    },
  );
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.controller,
    required this.conversation,
  });
  final AppController controller;
  final Conversation conversation;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final input = TextEditingController();
  late Future<List<Message>> messages;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    messages = widget.controller.api.messages(widget.conversation.id);
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void reload() => setState(() {
    messages = widget.controller.api.messages(widget.conversation.id);
  });
  Future<void> send() async {
    if (input.text.trim().isEmpty) return;
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      await widget.controller.api.request(
        'POST',
        '/api/v1/conversations/${widget.conversation.id}/messages',
        body: {'body': input.text.trim()},
      );
    });
    if (mounted) {
      setState(() => busy = false);
      if (ok) {
        input.clear();
        reload();
      }
    }
  }

  Future<void> action(String kind) async {
    setState(() => busy = true);
    bool ok;
    if (kind == 'unmatch') {
      final confirmed = await confirm(
        context,
        'Unmatch ${widget.conversation.name}?',
        'Your conversation will be removed.',
        'Unmatch',
      );
      if (!mounted) return;
      ok =
          confirmed &&
          await runAction(context, () async {
            await widget.controller.api.request(
              'POST',
              '/api/v1/conversations/${widget.conversation.id}/unmatch',
              body: {},
            );
          }, success: 'Unmatched.');
    } else {
      ok = await safetyAction(
        context,
        widget.controller,
        widget.conversation.otherId,
        widget.conversation.name,
        kind,
      );
    }
    if (mounted) {
      setState(() => busy = false);
      if (ok) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.conversation.name),
      actions: [
        PopupMenuButton<String>(
          enabled: !busy,
          onSelected: action,
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'unmatch', child: Text('Unmatch')),
            PopupMenuItem(value: 'report', child: Text('Report')),
            PopupMenuItem(value: 'block', child: Text('Block')),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Message>>(
              future: messages,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(errorMessage(snapshot.error!)),
                        TextButton(
                          onPressed: reload,
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  );
                }
                if (snapshot.connectionState != ConnectionState.done ||
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'You both expressed interest. Say hello when you feel ready.',
                      ),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    await runAction(context, () async {
                      reload();
                      await messages;
                    });
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final message in snapshot.data!)
                        Align(
                          alignment: message.mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 340),
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: message.mine
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(message.body),
                                const SizedBox(height: 4),
                                Text(
                                  localTime(message.createdAt),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'Your message',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : send,
                  child: const Text('Send'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    this.standalone = false,
  });
  final AppController controller;
  final bool standalone;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final code = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> verify() async {
    setState(() => busy = true);
    await runAction(context, () async {
      await widget.controller.api.request(
        'POST',
        '/api/v1/auth/verify',
        body: {'code': code.text.trim()},
      );
      await widget.controller.refresh();
      code.clear();
    }, success: 'Account verified.');
    if (mounted) setState(() => busy = false);
  }

  Future<void> requestVerification() async {
    setState(() => busy = true);
    await runAction(context, () async {
      await widget.controller.api.request(
        'POST',
        '/api/v1/auth/verify/request',
        body: {},
      );
    }, success: 'Check your email for a verification code.');
    if (mounted) setState(() => busy = false);
  }

  Future<void> logout() async {
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      await widget.controller.api.request(
        'POST',
        '/api/v1/auth/logout',
        body: {},
      );
      await widget.controller.api.clearSession();
      widget.controller.signedOut();
    });
    if (mounted) {
      setState(() => busy = false);
      if (ok && widget.standalone) Navigator.pop(context);
    }
  }

  Future<void> setPaused(bool value) async {
    setState(() => busy = true);
    await runAction(context, () async {
      await widget.controller.api.request(
        'PUT',
        '/api/v1/privacy',
        body: {'matching_paused': value},
      );
      await widget.controller.refresh();
    }, success: value ? 'Profile paused.' : 'Profile resumed.');
    if (mounted) setState(() => busy = false);
  }

  Future<void> delete() async {
    final password = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'This permanently deletes your account and associated data in this prototype. Enter your password to continue.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, password.text),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    password.dispose();
    if (value == null || !mounted) return;
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      await widget.controller.api.request(
        'DELETE',
        '/api/v1/account',
        body: {'password': value},
      );
      await widget.controller.api.clearSession();
      widget.controller.signedOut();
    }, success: 'Account deleted.');
    if (mounted) {
      setState(() => busy = false);
      if (ok && widget.standalone) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final me = widget.controller.account;
        if (me == null) return const SizedBox.shrink();
        return PageBody(
          title: 'Settings & safety',
          subtitle: 'Manage your account and review safety guidance.',
          children: [
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${me.email} · ${me.verified ? 'Verified' : 'Not verified'}',
                  ),
                  if (!me.verified) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Request a code to verify your email address.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: busy ? null : requestVerification,
                      child: const Text('Email a verification code'),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: code,
                      decoration: const InputDecoration(
                        labelText: 'Verification code',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: busy ? null : verify,
                      child: const Text('Verify account'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy ? null : logout,
                    child: const Text('Sign out'),
                  ),
                  TextButton(
                    onPressed: busy ? null : delete,
                    child: const Text('Delete account'),
                  ),
                ],
              ),
            ),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Safety & privacy',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pause my profile'),
                    subtitle: const Text(
                      'Hide introductions and pause conversations until you resume. Existing selections and conversations stay saved.',
                    ),
                    value: me.matchingPaused,
                    onChanged: busy ? null : setPaused,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Respect consent and boundaries. Never pressure someone to share personal information. Meet in a public place and tell someone you trust. You can block or report from an introduction or conversation.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Your individual answers and exact coordinates are not shown to other users. Reports remove the person from your view. This local prototype is not a production privacy service.',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
    return widget.standalone
        ? Scaffold(appBar: AppBar(), body: content)
        : content;
  }
}
