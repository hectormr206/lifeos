// The daily English reminder is an ORDINARY LifeOS reminder.
//
// It is created through the reminders service, so it shows up in
// "Recordatorios" where it can be edited, turned off or deleted like any
// other, rings through the same notification path, and is re-armed after a
// sync on each device. The feature never keeps a second alarm system of its
// own. Before creating one it looks for an existing daily English reminder
// (in any of the app's languages), so tapping twice never makes two.
library;

import 'package:flutter/material.dart';

import '../../reminders/data/local_reminders_service.dart';
import '../../reminders/domain/local_reminder.dart';

abstract interface class EnglishReminder {
  /// The time of the existing daily English reminder, or null.
  Future<TimeOfDay?> existingTime();

  /// Creates the daily reminder at [time], first ringing at its next
  /// occurrence.
  Future<void> create(TimeOfDay time);
}

class LocalEnglishReminder implements EnglishReminder {
  LocalEnglishReminder(
    this._service, {
    required this.text,
    required this.knownTexts,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalRemindersService _service;

  /// The reminder's text in the current language.
  final String text;

  /// Its text in every language the app ships, to recognise an existing one.
  final Set<String> knownTexts;
  final DateTime Function() _clock;

  @override
  Future<TimeOfDay?> existingTime() async {
    for (final r in await _service.list(now: _clock())) {
      if (r.recurrence == ReminderRecurrence.daily &&
          r.status != LocalReminderStatus.done &&
          knownTexts.contains(r.text)) {
        return TimeOfDay.fromDateTime(r.dueAt.toLocal());
      }
    }
    return null;
  }

  @override
  Future<void> create(TimeOfDay time) {
    final now = _clock();
    var due = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!due.isAfter(now)) due = due.add(const Duration(days: 1));
    return _service.create(
      text: text,
      dueAt: due,
      recurrence: ReminderRecurrence.daily,
    );
  }
}
