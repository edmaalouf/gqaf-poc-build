typedef Json = Map<String, dynamic>;

Json jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected an object from the server.');
  }
  return value;
}

String jsonString(Object? value) {
  if (value is! String) {
    throw const FormatException('Expected text from the server.');
  }
  return value;
}

int jsonInt(Object? value) {
  if (value is! int) {
    throw const FormatException('Expected a whole number from the server.');
  }
  return value;
}

double jsonNumber(Object? value) {
  if (value is! num) {
    throw const FormatException('Expected a number from the server.');
  }
  return value.toDouble();
}

bool jsonBool(Object? value) {
  if (value is! bool) {
    throw const FormatException('Expected a boolean from the server.');
  }
  return value;
}

List<T> jsonList<T>(Object? value, T Function(Object?) parse) {
  if (value is! List) {
    throw const FormatException('Expected a list from the server.');
  }
  return value.map(parse).toList(growable: false);
}

class Profile {
  const Profile({
    required this.name,
    required this.birthDate,
    required this.city,
    required this.bio,
    required this.gender,
    required this.intention,
    required this.interests,
    required this.lifestyle,
    required this.latitude,
    required this.longitude,
  });

  factory Profile.fromJson(Object? value) {
    final json = jsonObject(value);
    return Profile(
      name: jsonString(json['name']),
      birthDate: jsonString(json['birth_date']),
      city: jsonString(json['city']),
      bio: jsonString(json['bio']),
      gender: jsonString(json['gender']),
      intention: jsonString(json['intention']),
      interests: jsonList(json['interests'], jsonString),
      lifestyle: jsonObject(
        json['lifestyle'],
      ).map((key, value) => MapEntry(key, jsonString(value))),
      latitude: jsonNumber(json['latitude']),
      longitude: jsonNumber(json['longitude']),
    );
  }

  final String name, birthDate, city, bio, gender, intention;
  final List<String> interests;
  final Map<String, String> lifestyle;
  final double latitude, longitude;

  Json toJson() => {
    'name': name,
    'birth_date': birthDate,
    'city': city,
    'bio': bio,
    'gender': gender,
    'intention': intention,
    'interests': interests,
    'lifestyle': lifestyle,
    'latitude': latitude,
    'longitude': longitude,
  };
}

class Preferences {
  const Preferences({
    required this.minAge,
    required this.maxAge,
    required this.distance,
    required this.genders,
    required this.intentions,
    required this.dealbreakers,
  });

  factory Preferences.fromJson(Object? value) {
    final json = jsonObject(value);
    return Preferences(
      minAge: jsonInt(json['min_age']),
      maxAge: jsonInt(json['max_age']),
      distance: jsonNumber(json['distance']),
      genders: jsonList(json['genders'], jsonString),
      intentions: jsonList(json['intentions'], jsonString),
      dealbreakers: jsonObject(
        json['dealbreakers'],
      ).map((key, value) => MapEntry(key, jsonString(value))),
    );
  }

  final int minAge, maxAge;
  final double distance;
  final List<String> genders, intentions;
  final Map<String, String> dealbreakers;

  Json toJson() => {
    'min_age': minAge,
    'max_age': maxAge,
    'distance': distance,
    'genders': genders,
    'intentions': intentions,
    'dealbreakers': dealbreakers,
  };
}

class Account {
  const Account({
    required this.id,
    required this.email,
    required this.verified,
    required this.profile,
    required this.preferences,
    required this.photo,
    required this.answers,
    required this.ready,
    required this.matchingPaused,
  });

  factory Account.fromJson(Object? value) {
    final json = jsonObject(value);
    return Account(
      id: jsonInt(json['id']),
      email: jsonString(json['email']),
      verified: jsonBool(json['verified']),
      profile: json['profile'] == null
          ? null
          : Profile.fromJson(json['profile']),
      preferences: json['preferences'] == null
          ? null
          : Preferences.fromJson(json['preferences']),
      photo: jsonString(json['photo']),
      answers: jsonObject(
        json['answers'],
      ).map((key, value) => MapEntry(int.parse(key), jsonInt(value))),
      ready: jsonBool(json['ready']),
      matchingPaused: jsonBool(json['matching_paused']),
    );
  }

  final int id;
  final String email, photo;
  final bool verified, ready, matchingPaused;
  final Profile? profile;
  final Preferences? preferences;
  final Map<int, int> answers;
}

class Question {
  const Question(this.id, this.category, this.text);
  factory Question.fromJson(Object? value) {
    final json = jsonObject(value);
    return Question(
      jsonInt(json['id']),
      jsonString(json['category']),
      jsonString(json['text']),
    );
  }
  final int id;
  final String category, text;
}

class Introduction {
  const Introduction({
    required this.id,
    required this.name,
    required this.age,
    required this.distanceLabel,
    required this.intention,
    required this.bio,
    required this.score,
    required this.breakdown,
    required this.sharedInterests,
    required this.similarities,
    required this.reaction,
  });

  factory Introduction.fromJson(Object? value) {
    final json = jsonObject(value);
    return Introduction(
      id: jsonInt(json['id']),
      name: jsonString(json['name']),
      age: jsonInt(json['age']),
      distanceLabel: jsonString(json['distance_label']),
      intention: jsonString(json['intention']),
      bio: jsonString(json['bio']),
      score: jsonNumber(json['score']),
      breakdown: jsonObject(
        json['breakdown'],
      ).map((key, value) => MapEntry(key, jsonNumber(value))),
      sharedInterests: jsonList(json['shared_interests'], jsonString),
      similarities: jsonList(json['similarities'], jsonString),
      reaction: json['reaction'] == null ? null : jsonString(json['reaction']),
    );
  }

  final int id, age;
  final String name, distanceLabel, intention, bio;
  final double score;
  final Map<String, double> breakdown;
  final List<String> sharedInterests, similarities;
  final String? reaction;
}

class WeeklyIntroductions {
  const WeeklyIntroductions(this.cycle, this.introductions, this.invitations);
  factory WeeklyIntroductions.fromJson(Object? value) {
    final json = jsonObject(value);
    final cycle = json['cycle'];
    return WeeklyIntroductions(
      cycle == null
          ? null
          : DateTime.parse(jsonString(jsonObject(cycle)['id'])),
      jsonList(json['matches'], Introduction.fromJson),
      jsonList(json['invitations'], Introduction.fromJson),
    );
  }
  final DateTime? cycle;
  final List<Introduction> introductions, invitations;
}

class Conversation {
  const Conversation(this.id, this.otherId, this.name, this.unread);
  factory Conversation.fromJson(Object? value) {
    final json = jsonObject(value);
    return Conversation(
      jsonInt(json['id']),
      jsonInt(json['other_id']),
      jsonString(json['name']),
      jsonInt(json['unread']),
    );
  }
  final int id, otherId, unread;
  final String name;
}

class Message {
  const Message(this.id, this.mine, this.body, this.createdAt);
  factory Message.fromJson(Object? value) {
    final json = jsonObject(value);
    return Message(
      jsonInt(json['id']),
      jsonBool(json['mine']),
      jsonString(json['body']),
      DateTime.parse(jsonString(json['created_at'])),
    );
  }
  final int id;
  final bool mine;
  final String body;
  final DateTime createdAt;
}
