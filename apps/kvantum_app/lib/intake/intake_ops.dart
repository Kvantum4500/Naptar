import 'package:kvantum_core/kvantum_core.dart';
import 'package:uuid/uuid.dart';

import '../data/record_repository.dart';

/// What the app does to the food and fluid log: every change is written into
/// the month record of the day it belongs to (see intake.dart in the core), and
/// every one has a way back, so a deletion can be taken back with "Visszavonás".
class IntakeOps {
  IntakeOps(this._repo, {String Function()? newId, this.onChanged})
    : _newId = newId ?? (() => const Uuid().v4());

  final RecordRepository _repo;
  final String Function() _newId;

  /// Told after every change (the app asks the sync to run).
  final void Function()? onChanged;

  Future<T> _write<T>(Future<T> Function() body) async {
    final result = await _repo.db.transaction(body);
    onChanged?.call();
    return result;
  }

  /// Writes [entry] (a food that is new, or an old one changed) into the month
  /// of its day.
  Future<void> _putFood(FoodEntry e) =>
      _repo.edit(kindIntake, intakeMonthId(e.day), e.fields);

  Future<void> _putFluid(FluidEntry e) =>
      _repo.edit(kindIntake, intakeMonthId(e.day), e.fields);

  /// Takes the food out of the month of its day.
  Future<void> _dropFood(FoodEntry e) =>
      _repo.edit(kindIntake, intakeMonthId(e.day), FoodEntry.removal(e.id));

  Future<void> _dropFluid(FluidEntry e) =>
      _repo.edit(kindIntake, intakeMonthId(e.day), FluidEntry.removal(e.id));

  /// An id for a new entry (a form makes its entry itself, and needs one).
  String newId() => _newId();

  /// Writes a food that a form has made (a new one, or an old one changed;
  /// see [saveFood] when its day may have moved to another month).
  Future<void> putFood(FoodEntry entry) => _write(() => _putFood(entry));

  Future<void> putFluid(FluidEntry entry) => _write(() => _putFluid(entry));

  /// Logs a food (the values are checked: an [ArgumentError] says what is
  /// wrong). Returns the entry, which is what undoing it needs.
  Future<FoodEntry> addFood({
    required DateTime day,
    required int minute,
    required Meal meal,
    String name = '',
    int? kcal,
    int? protein,
    int? carbs,
    int? fat,
  }) async {
    final entry = FoodEntry.checked(
      id: _newId(),
      day: day,
      minute: minute,
      meal: meal,
      name: name,
      kcal: kcal,
      protein: protein,
      carbs: carbs,
      fat: fat,
    );
    await _write(() => _putFood(entry));
    return entry;
  }

  /// Logs a drink.
  Future<FluidEntry> addFluid({
    required DateTime day,
    required int minute,
    required int ml,
    DrinkKind kind = DrinkKind.water,
  }) async {
    final entry = FluidEntry.checked(
      id: _newId(),
      day: day,
      minute: minute,
      ml: ml,
      kind: kind,
    );
    await _write(() => _putFluid(entry));
    return entry;
  }

  /// Saves a food that was changed ([after] has the id of [before]). When its
  /// day moved to another month, it is taken out of the old one in the same
  /// transaction.
  Future<void> saveFood(FoodEntry before, FoodEntry after) {
    assert(before.id == after.id, 'a changed food keeps its id');
    return _write(() async {
      await _putFood(after);
      if (intakeMonthId(before.day) != intakeMonthId(after.day)) {
        await _dropFood(before);
      }
    });
  }

  /// The same for a drink.
  Future<void> saveFluid(FluidEntry before, FluidEntry after) {
    assert(before.id == after.id, 'a changed drink keeps its id');
    return _write(() async {
      await _putFluid(after);
      if (intakeMonthId(before.day) != intakeMonthId(after.day)) {
        await _dropFluid(before);
      }
    });
  }

  /// Removes a food; [restoreFood] brings it back.
  Future<void> removeFood(FoodEntry e) => _write(() => _dropFood(e));

  Future<void> removeFluid(FluidEntry e) => _write(() => _dropFluid(e));

  /// Brings back a food that was removed (writes it again, with a newer stamp
  /// than the removal, so it wins on every device that has seen the removal).
  Future<bool> restoreFood(FoodEntry e) async {
    await _write(() => _putFood(e));
    return true;
  }

  Future<bool> restoreFluid(FluidEntry e) async {
    await _write(() => _putFluid(e));
    return true;
  }

  /// Takes a change back: the old values are written again, and the new place
  /// is emptied when the entry had moved to another month.
  Future<bool> undoSaveFood(FoodEntry before, FoodEntry after) async {
    await _write(() async {
      await _putFood(before);
      if (intakeMonthId(before.day) != intakeMonthId(after.day)) {
        await _dropFood(after);
      }
    });
    return true;
  }

  Future<bool> undoSaveFluid(FluidEntry before, FluidEntry after) async {
    await _write(() async {
      await _putFluid(before);
      if (intakeMonthId(before.day) != intakeMonthId(after.day)) {
        await _dropFluid(after);
      }
    });
    return true;
  }
}
