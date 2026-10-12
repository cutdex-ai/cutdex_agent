import 'package:cutdex_agent/cutdex_agent.dart';

import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_user_choice_validate.dart' show validateUserChoiceConflict;

const freeTextGoalChange = '取消原来的10秒和20秒目标，改成15秒。请仅执行15秒的新目标，核验后汇总。';

/// Tests replacing both incompatible goals with a host-submitted free-text goal.
Future<Map<String, Object?>> validateFreeTextConflict(ModelAdapter model) =>
    validateUserChoiceConflict(
      model,
      freeText: freeTextGoalChange,
      expectedDuration: 15,
    );

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateFreeTextConflict,
  label: 'LIVE_FREE_TEXT_GOAL',
);
