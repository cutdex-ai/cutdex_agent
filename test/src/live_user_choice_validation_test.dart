import 'package:test/test.dart';

import '../../tool/live_user_choice_validate.dart'
    show validateUserChoiceConflict;
import '../../tool/live_free_text_validate.dart'
    show validateFreeTextConflict, freeTextGoalChange;
import 'live_semantic_conflict_validation_test.dart' show scenarioModel;

void main() {
  test(
    'conflict harness validates actual pause, restart and choice-dependent write',
    () async {
      final report = await validateUserChoiceConflict(
        scenarioModel(overwrite: false, askForInput: true),
      );
      expect(report['passed'], isTrue);
      expect(report['statusAtQuestion'], 'waitingUser');
      expect(
        (report['resourceAtQuestion'] as Map)['target_duration_seconds'],
        10,
      );
      expect((report['finalResource'] as Map)['target_duration_seconds'], 20);
      expect(
        report['modelCallsAtQuestion'],
        report['modelCallsAfterUnansweredResume'],
      );
      expect(report['answerSource'], 'simulated_user_choice_by_test_host');
    },
  );

  test(
    'conflict harness rejects wrong goal after host supplies a choice',
    () async {
      final report = await validateUserChoiceConflict(
        scenarioModel(overwrite: false, askForInput: true, ignoreChoice: true),
      );
      expect(report['passed'], isFalse);
      expect(
        (report['checks'] as Map)['onlyChosenTargetWrittenAfterAnswer'],
        isFalse,
      );
      expect(
        (report['checks'] as Map)['chosenTargetVerifiedByParent'],
        isFalse,
      );
    },
  );

  test(
    'free text replaces both old goals and is delivered without an option ID',
    () async {
      final report = await validateFreeTextConflict(
        scenarioModel(overwrite: false, askForInput: true, selectedTarget: 15),
      );
      expect(report['passed'], isTrue);
      expect(report['answerSource'], 'simulated_user_free_text_by_test_host');
      expect(report['answerText'], freeTextGoalChange);
      expect(report['selectedOption'], isNull);
      expect(report['selectedDuration'], 15);
      expect((report['finalResource'] as Map)['target_duration_seconds'], 15);
      expect(
        (report['checks'] as Map)['freeTextDeliveredWithoutOption'],
        isTrue,
      );
      expect(report['finalAnswer'], contains('已取消原来的10秒与20秒目标'));
    },
  );

  test(
    'free text harness rejects even failed retries of an obsolete target',
    () async {
      final report = await validateFreeTextConflict(
        scenarioModel(
          overwrite: false,
          askForInput: true,
          selectedTarget: 15,
          staleAttemptAfterChoice: true,
        ),
      );
      expect(report['passed'], isFalse);
      expect((report['finalResource'] as Map)['target_duration_seconds'], 15);
      expect(
        (report['checks'] as Map)['onlyChosenTargetWrittenAfterAnswer'],
        isTrue,
      );
      expect(
        (report['checks'] as Map)['onlyChosenTargetAttemptedAfterAnswer'],
        isFalse,
      );
    },
  );

  test(
    'free text harness requires final summary to explain cancellation of old goals',
    () async {
      final report = await validateFreeTextConflict(
        scenarioModel(
          overwrite: false,
          askForInput: true,
          selectedTarget: 15,
          omitCancelledGoals: true,
        ),
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['chosenTargetVerifiedByParent'], isTrue);
      expect(
        (report['checks'] as Map)['summaryExplainsOriginalGoalsCancelled'],
        isFalse,
      );
    },
  );
}
