import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image_picker/image_picker.dart';

import 'app.dart';
import 'models.dart';
import 'social_screens.dart';

const genders = ['woman', 'man', 'nonbinary', 'other'];
const intentions = ['serious', 'casual', 'exploring', 'other'];
const lifestyleKeys = ['smoking', 'drinking', 'children'];

String label(String value) => switch (value) {
  'woman' => 'Woman',
  'man' => 'Man',
  'nonbinary' => 'Nonbinary',
  'serious' => 'Long-term relationship',
  'casual' => 'Casual dating',
  'exploring' => 'Exploring',
  'other' => 'Other',
  _ => '${value[0].toUpperCase()}${value.substring(1)}',
};

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final me = controller.account!;
    final items = <({String title, bool done, Widget page})>[
      (
        title: 'Account verification',
        done: me.verified,
        page: SettingsScreen(controller: controller, standalone: true),
      ),
      (
        title: 'Your profile',
        done: me.profile != null,
        page: ProfileEditor(controller: controller),
      ),
      (
        title: me.photo == 'pending'
            ? 'Photo awaiting review'
            : 'Approved photo',
        done: me.photo == 'approved',
        page: ProfileOverview(controller: controller, standalone: true),
      ),
      (
        title: 'Dating preferences',
        done: me.preferences != null,
        page: PreferencesEditor(controller: controller),
      ),
      (
        title: 'Compatibility questions (${me.answers.length}/64)',
        done: me.answers.length == 64,
        page: QuestionnaireScreen(controller: controller, standalone: true),
      ),
    ];
    final count = items.where((item) => item.done).length;
    return PageBody(
      title: 'Complete your profile',
      subtitle: 'Finish each step to be considered for weekly introductions.',
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$count of 5 complete',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: count / 5,
                semanticsLabel: 'Onboarding progress, $count of 5 complete',
              ),
              const SizedBox(height: 12),
              for (final item in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    item.done ? Icons.check_circle : Icons.circle_outlined,
                  ),
                  title: Text(item.title),
                  subtitle: Text(item.done ? 'Complete' : 'Not complete'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openPage(context, item.page),
                ),
            ],
          ),
        ),
        const Text(
          'Your answers are private. Introductions are selected on Mondays; compatibility is an estimate, not a guarantee of relationship success.',
        ),
      ],
    );
  }
}

class ProfileOverview extends StatefulWidget {
  const ProfileOverview({
    super.key,
    required this.controller,
    this.standalone = false,
  });
  final AppController controller;
  final bool standalone;
  @override
  State<ProfileOverview> createState() => _ProfileOverviewState();
}

class _ProfileOverviewState extends State<ProfileOverview> {
  final picker = ImagePicker();
  XFile? selected;
  bool busy = false;
  int photoRevision = 0;
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      recoverPhoto();
    }
  }

  Future<void> recoverPhoto() async {
    await runAction(context, () async {
      final result = await picker.retrieveLostData();
      if (result.exception != null) throw result.exception!;
      if (result.files != null && result.files!.isNotEmpty && mounted) {
        setState(() => selected = result.files!.first);
      }
    });
  }

  Future<void> choose() async {
    await runAction(context, () async {
      final file = await picker.pickImage(source: ImageSource.gallery);
      if (mounted && file != null) setState(() => selected = file);
    });
  }

  Future<void> upload() async {
    final file = selected;
    if (file == null) return;
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      if (await file.length() > 3900000) {
        throw const FormatException('Choose an image smaller than 3.9 MB.');
      }
      await widget.controller.api.uploadPhoto(await file.readAsBytes());
      await widget.controller.refresh();
    }, success: 'Photo submitted for review.');
    if (mounted) {
      setState(() {
        busy = false;
        if (ok) {
          selected = null;
          photoRevision++;
        }
      });
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
          title: 'Your profile',
          subtitle: 'Tell potential matches about yourself.',
          children: [
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    me.profile?.name ?? 'Your details',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    me.profile == null
                        ? 'Add your profile to get started.'
                        : '${me.profile!.city} · ${label(me.profile!.intention)}',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => openPage(
                      context,
                      ProfileEditor(controller: widget.controller),
                    ),
                    child: const Text('Edit profile'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => openPage(
                      context,
                      PreferencesEditor(controller: widget.controller),
                    ),
                    child: const Text('Edit preferences'),
                  ),
                ],
              ),
            ),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your photo',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Status: ${me.photo}. A clear JPEG or PNG is reviewed before appearing in introductions.',
                  ),
                  if (me.photo != 'missing') ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 200,
                      child: ProfilePhoto(
                        controller: widget.controller,
                        userId: me.id,
                        name: 'Your submitted photo',
                        version: '${me.photo}-$photoRevision',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (selected != null)
                    const Text('Photo selected. Submit it when you are ready.'),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy ? null : choose,
                        child: const Text('Choose photo'),
                      ),
                      FilledButton(
                        onPressed: selected == null || busy ? null : upload,
                        child: Text(busy ? 'Submitting…' : 'Submit for review'),
                      ),
                    ],
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

class ProfilePhoto extends StatefulWidget {
  const ProfilePhoto({
    super.key,
    required this.controller,
    required this.userId,
    required this.name,
    this.version = '',
  });
  final AppController controller;
  final int userId;
  final String name, version;
  @override
  State<ProfilePhoto> createState() => _ProfilePhotoState();
}

class _ProfilePhotoState extends State<ProfilePhoto> {
  late Future<Uint8List> photo;
  @override
  void initState() {
    super.initState();
    photo = widget.controller.api.photo(widget.userId);
  }

  @override
  void didUpdateWidget(ProfilePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.version != widget.version) {
      photo = widget.controller.api.photo(widget.userId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: photo,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: Text('Photo unavailable: ${errorMessage(snapshot.error!)}'),
        );
      }
      if (snapshot.connectionState != ConnectionState.done ||
          !snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          width: double.infinity,
          semanticLabel: widget.name,
        ),
      );
    },
  );
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.controller});
  final AppController controller;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _EditorGuard extends StatefulWidget {
  const _EditorGuard({
    required this.dirty,
    required this.busy,
    required this.child,
  });
  final bool dirty, busy;
  final Widget child;

  @override
  State<_EditorGuard> createState() => _EditorGuardState();
}

class _EditorGuardState extends State<_EditorGuard> {
  bool asking = false;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !widget.dirty && !widget.busy,
    onPopInvokedWithResult: (didPop, _) async {
      if (didPop || widget.busy || asking) return;
      asking = true;
      final discard = await confirm(
        context,
        'Discard changes?',
        'Your changes have not been saved.',
        'Discard',
      );
      asking = false;
      if (discard && context.mounted) Navigator.of(context).pop();
    },
    child: widget.child,
  );
}

class _ProfileEditorState extends State<ProfileEditor> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  String? gender, intention;
  bool busy = false, dirty = false;
  @override
  void initState() {
    super.initState();
    final p = widget.controller.account!.profile;
    fields = {
      'name': TextEditingController(text: p?.name),
      'birth_date': TextEditingController(text: p?.birthDate),
      'city': TextEditingController(text: p?.city),
      'latitude': TextEditingController(text: p?.latitude.toString()),
      'longitude': TextEditingController(text: p?.longitude.toString()),
      'bio': TextEditingController(text: p?.bio),
      'interests': TextEditingController(text: p?.interests.join(', ')),
      for (final k in lifestyleKeys)
        k: TextEditingController(text: p?.lifestyle[k]),
    };
    gender = p?.gender;
    intention = p?.intention;
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget field(
    String key,
    String title, {
    String? helper,
    int maxLines = 1,
    TextInputType? keyboard,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: fields[key],
      maxLines: maxLines,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: title,
        helperText: helper,
        helperMaxLines: 3,
      ),
      validator: (v) {
        if (v == null || v.trim().isEmpty) return 'This field is required.';
        if (numeric && double.tryParse(v) == null) return 'Enter a number.';
        return null;
      },
    ),
  );
  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      await widget.controller.api.request(
        'PUT',
        '/api/v1/profile',
        body: {
          'name': fields['name']!.text.trim(),
          'birth_date': fields['birth_date']!.text.trim(),
          'city': fields['city']!.text.trim(),
          'bio': fields['bio']!.text.trim(),
          'gender': gender,
          'intention': intention,
          'latitude': double.parse(fields['latitude']!.text),
          'longitude': double.parse(fields['longitude']!.text),
          'interests': fields['interests']!.text
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList(),
          'lifestyle': {
            for (final k in lifestyleKeys) k: fields[k]!.text.trim(),
          },
        },
      );
      await widget.controller.refresh();
    }, success: 'Profile saved.');
    if (mounted) {
      setState(() => busy = false);
      if (ok) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => _EditorGuard(
    dirty: dirty,
    busy: busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Edit profile')),
      body: Form(
        key: form,
        onChanged: () {
          if (!dirty) setState(() => dirty = true);
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            field('name', 'First name'),
            field(
              'birth_date',
              'Date of birth (YYYY-MM-DD)',
              keyboard: TextInputType.datetime,
            ),
            field(
              'city',
              'City or general area',
              helper:
                  'Never enter a street address. Exact coordinates are not shown to other users.',
            ),
            field(
              'latitude',
              'Approximate latitude',
              keyboard: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              numeric: true,
            ),
            field(
              'longitude',
              'Approximate longitude',
              helper:
                  'Enter approximate city coordinates for distance matching.',
              keyboard: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              numeric: true,
            ),
            field(
              'bio',
              'About you',
              maxLines: 4,
              helper:
                  'Visible to introductions. Do not include your address or sensitive information.',
            ),
            DropdownButtonFormField<String>(
              initialValue: gender,
              decoration: const InputDecoration(labelText: 'Gender'),
              items: genders
                  .map((v) => DropdownMenuItem(value: v, child: Text(label(v))))
                  .toList(),
              onChanged: (v) => setState(() => gender = v),
              validator: (v) => v == null ? 'Choose a gender.' : null,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: intention,
              decoration: const InputDecoration(labelText: 'Dating intention'),
              items: intentions
                  .map((v) => DropdownMenuItem(value: v, child: Text(label(v))))
                  .toList(),
              onChanged: (v) => setState(() => intention = v),
              validator: (v) => v == null ? 'Choose an intention.' : null,
            ),
            const SizedBox(height: 16),
            field('interests', 'Interests, separated by commas'),
            for (final k in lifestyleKeys) field(k, label(k)),
            const Text(
              'Use simple terms such as “yes”, “no” or “sometimes”; dealbreakers compare these values exactly.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save profile'),
            ),
          ],
        ),
      ),
    ),
  );
}

class PreferencesEditor extends StatefulWidget {
  const PreferencesEditor({super.key, required this.controller});
  final AppController controller;
  @override
  State<PreferencesEditor> createState() => _PreferencesEditorState();
}

class _PreferencesEditorState extends State<PreferencesEditor> {
  final form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late final Set<String> selectedGenders, selectedIntentions;
  bool busy = false, dirty = false;
  @override
  void initState() {
    super.initState();
    final p = widget.controller.account!.preferences;
    fields = {
      'min': TextEditingController(text: '${p?.minAge ?? 18}'),
      'max': TextEditingController(text: '${p?.maxAge ?? 99}'),
      'distance': TextEditingController(text: '${p?.distance ?? 50}'),
      for (final k in lifestyleKeys)
        k: TextEditingController(text: p?.dealbreakers[k]),
    };
    selectedGenders = {...?p?.genders};
    selectedIntentions = {...?p?.intentions};
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget numberField(String key, String title, {bool integer = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextFormField(
          controller: fields[key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: title),
          validator: (v) =>
              (integer ? int.tryParse(v ?? '') : double.tryParse(v ?? '')) ==
                  null
              ? 'Enter a valid number.'
              : null,
        ),
      );
  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    if (selectedGenders.isEmpty || selectedIntentions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose at least one gender and intention.'),
        ),
      );
      return;
    }
    setState(() => busy = true);
    final ok = await runAction(context, () async {
      await widget.controller.api.request(
        'PUT',
        '/api/v1/preferences',
        body: {
          'min_age': int.parse(fields['min']!.text),
          'max_age': int.parse(fields['max']!.text),
          'distance': double.parse(fields['distance']!.text),
          'genders': selectedGenders.toList(),
          'intentions': selectedIntentions.toList(),
          'dealbreakers': {
            for (final k in lifestyleKeys)
              if (fields[k]!.text.trim().isNotEmpty) k: fields[k]!.text.trim(),
          },
        },
      );
      await widget.controller.refresh();
    }, success: 'Preferences saved.');
    if (mounted) {
      setState(() => busy = false);
      if (ok) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => _EditorGuard(
    dirty: dirty,
    busy: busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Dating preferences')),
      body: Form(
        key: form,
        onChanged: () {
          if (!dirty) setState(() => dirty = true);
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Both people must meet each other’s preferences.'),
            const SizedBox(height: 16),
            numberField('min', 'Minimum age', integer: true),
            numberField('max', 'Maximum age', integer: true),
            numberField('distance', 'Maximum distance (km)'),
            const Text(
              'For privacy, distance checks include a safety margin. Smaller limits may yield no matches.',
            ),
            Text(
              'Genders you want to date',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final value in genders)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label(value)),
                value: selectedGenders.contains(value),
                onChanged: (checked) => setState(() {
                  dirty = true;
                  if (checked == true) {
                    selectedGenders.add(value);
                  } else {
                    selectedGenders.remove(value);
                  }
                }),
              ),
            Text(
              'Dating intentions',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final value in intentions)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label(value)),
                value: selectedIntentions.contains(value),
                onChanged: (checked) => setState(() {
                  dirty = true;
                  if (checked == true) {
                    selectedIntentions.add(value);
                  } else {
                    selectedIntentions.remove(value);
                  }
                }),
              ),
            Text(
              'Dealbreakers',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Optional. A match’s lifestyle answer must match exactly.',
            ),
            const SizedBox(height: 12),
            for (final k in lifestyleKeys)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextFormField(
                  controller: fields[k],
                  decoration: InputDecoration(
                    labelText: 'Required ${label(k).toLowerCase()} answer',
                  ),
                ),
              ),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save preferences'),
            ),
          ],
        ),
      ),
    ),
  );
}

class QuestionnaireScreen extends StatefulWidget {
  const QuestionnaireScreen({
    super.key,
    required this.controller,
    this.standalone = false,
  });
  final AppController controller;
  final bool standalone;
  @override
  State<QuestionnaireScreen> createState() => _QuestionnaireScreenState();
}

class _QuestionnaireScreenState extends State<QuestionnaireScreen> {
  late Future<List<Question>> questions;
  int? currentQuestion;
  double dragOffset = 0;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    questions = widget.controller.api.questions();
  }

  Future<void> answer(List<Question> all, int id, int value) async {
    setState(() => busy = true);
    final saved = await runAction(context, () async {
      await widget.controller.api.request(
        'PUT',
        '/api/v1/answers/$id',
        body: {'value': value},
      );
      await widget.controller.refresh();
    });
    if (mounted) {
      setState(() {
        busy = false;
        dragOffset = 0;
        if (saved) {
          final next = all.indexWhere(
            (question) =>
                question.id != id &&
                !widget.controller.account!.answers.containsKey(question.id),
          );
          currentQuestion = next < 0 ? all.indexWhere((q) => q.id == id) : next;
        }
      });
    }
  }

  void answerFromSwipe(List<Question> all, Question question) {
    if (busy || dragOffset.abs() < 72) {
      setState(() => dragOffset = 0);
      return;
    }
    final strongly = dragOffset.abs() >= 140;
    final value = dragOffset > 0 ? (strongly ? 5 : 4) : (strongly ? 1 : 2);
    answer(all, question.id, value);
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<List<Question>>(
      future: questions,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(errorMessage(snapshot.error!)),
                TextButton(
                  onPressed: () => setState(() {
                    questions = widget.controller.api.questions();
                  }),
                  child: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final all = snapshot.data!;
        final categories = all.map((q) => q.category).toSet().toList();
        if (categories.length != 8 || all.length != 64) {
          return const Center(
            child: Text(
              'The questionnaire is unavailable. Please try again later.',
            ),
          );
        }
        final account = widget.controller.account;
        if (account == null) return const SizedBox.shrink();
        final answers = account.answers;
        final firstUnanswered = all.indexWhere(
          (question) => !answers.containsKey(question.id),
        );
        final index =
            currentQuestion ?? (firstUnanswered < 0 ? 0 : firstUnanswered);
        final question = all[index];
        final categoryIndex = categories.indexOf(question.category);
        final picked = answers[question.id];
        final labels = switch (picked) {
          1 => 'Strongly disagree',
          2 => 'Disagree',
          3 => 'Neutral',
          4 => 'Agree',
          5 => 'Strongly agree',
          _ => null,
        };
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
              children: [
                Text(
                  'Get to know your kind of person.',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'Your answers stay private. There are no right ones.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${answers.length} of 64',
                      style: const TextStyle(
                        color: Color(0xff315e46),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${(answers.length * 100 / 64).round()}% complete',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: answers.length / 64,
                    semanticsLabel:
                        'Questionnaire progress, ${answers.length} of 64 answered',
                    color: const Color(0xff567d60),
                    backgroundColor: const Color(0xffe1e9df),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xffe5eee3),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        question.category,
                        style: const TextStyle(
                          color: Color(0xff315b42),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${index + 1} / 64',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  key: ValueKey('question-card-${question.id}'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: busy
                      ? null
                      : (details) => setState(() {
                          final delta = details.primaryDelta ?? 0;
                          dragOffset = (dragOffset + delta)
                              .clamp(-170, 170)
                              .toDouble();
                        }),
                  onHorizontalDragEnd: busy
                      ? null
                      : (_) => answerFromSwipe(all, question),
                  child: Transform.translate(
                    offset: Offset(dragOffset * 0.18, 0),
                    child: Transform.rotate(
                      angle: dragOffset / 900,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 280),
                        padding: const EdgeInsets.all(26),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: const Color(0xffd7ddd4)),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x14182e27),
                              blurRadius: 20,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (dragOffset.abs() > 25)
                              Align(
                                alignment: dragOffset > 0
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Text(
                                  dragOffset > 0 ? 'AGREE' : 'DISAGREE',
                                  style: TextStyle(
                                    color: const Color(0xff315e46).withValues(
                                      alpha: (dragOffset.abs() / 120)
                                          .clamp(0.35, 1)
                                          .toDouble(),
                                    ),
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.4,
                                  ),
                                ),
                              ),
                            if (dragOffset.abs() > 25)
                              const SizedBox(height: 16),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 240),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) =>
                                  FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(
                                      position: Tween<Offset>(
                                        begin: const Offset(0.04, 0),
                                        end: Offset.zero,
                                      ).animate(animation),
                                      child: child,
                                    ),
                                  ),
                              child: Text(
                                question.text,
                                key: ValueKey(question.id),
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(
                                      color: const Color(0xff202b26),
                                      fontWeight: FontWeight.w700,
                                      height: 1.25,
                                    ),
                              ),
                            ),
                            if (labels != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                'Your answer: $labels',
                                style: const TextStyle(
                                  color: Color(0xff315b42),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            Text(
                              busy
                                  ? 'Saving your answer…'
                                  : 'Swipe right to agree · left to disagree',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 7,
                  runSpacing: 8,
                  children: [
                    _AnswerChoice(
                      label: 'Strongly disagree',
                      value: 1,
                      selected: picked == 1,
                      enabled: !busy,
                      onTap: () => answer(all, question.id, 1),
                    ),
                    _AnswerChoice(
                      label: 'Disagree',
                      value: 2,
                      selected: picked == 2,
                      enabled: !busy,
                      onTap: () => answer(all, question.id, 2),
                    ),
                    _AnswerChoice(
                      label: 'Neutral',
                      value: 3,
                      selected: picked == 3,
                      enabled: !busy,
                      onTap: () => answer(all, question.id, 3),
                    ),
                    _AnswerChoice(
                      label: 'Agree',
                      value: 4,
                      selected: picked == 4,
                      enabled: !busy,
                      onTap: () => answer(all, question.id, 4),
                    ),
                    _AnswerChoice(
                      label: 'Strongly agree',
                      value: 5,
                      selected: picked == 5,
                      enabled: !busy,
                      onTap: () => answer(all, question.id, 5),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                    'Section ${categoryIndex + 1} of 8 · one question at a time',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    return widget.standalone
        ? Scaffold(appBar: AppBar(), body: content)
        : content;
  }
}

class _AnswerChoice extends StatelessWidget {
  const _AnswerChoice({
    required this.label,
    required this.value,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final String label;
  final int value;
  final bool selected, enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$label, answer value $value',
    child: OutlinedButton(
      onPressed: enabled ? onTap : null,
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? Colors.white : const Color(0xff315b42),
        backgroundColor: selected
            ? const Color(0xff315b42)
            : const Color(0xfffffefa),
        side: BorderSide(
          color: selected ? const Color(0xff315b42) : const Color(0xffcbd9cc),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: Text(label),
    ),
  );
}
