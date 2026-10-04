import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/src/tools/schema.dart';
import 'package:test/test.dart';
import 'agent_test.dart' show ScriptedModel;

void main() {
  final schema = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'required': {'type': 'string'},
      'optional': {'type': 'string'},
      'nullable': {
        'type': ['string', 'null'],
      },
      'items': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'value': {'type': 'integer'},
          },
        },
      },
    },
    'required': ['required'],
  };
  test(
    'wire schemas describe null omission without changing host contracts',
    () {
      final wire = modelToolSchema(schema);
      final properties = wire['properties'] as Map;
      expect(
        (properties['optional'] as Map)['anyOf'],
        contains(equals({'type': 'null'})),
      );
      expect((schema['properties'] as Map)['optional'], {'type': 'string'});
      expect(properties['required'], {'type': 'string'});
      expect(properties['nullable'], {
        'type': ['string', 'null'],
      });
      final args = normalizeToolArguments({
        'required': null,
        'optional': null,
        'nullable': null,
        'unknown': null,
        'items': [
          {'value': null},
        ],
      }, schema);
      expect(args, {
        'required': null,
        'nullable': null,
        'unknown': null,
        'items': [{}],
      });
    },
  );
  test(
    'runtime journals normalized arguments before host validation and execution',
    () async {
      var turns = 0;
      Map<String, Object?>? received;
      final manager = SessionManager(
        store: InMemorySessionStore(),
        model: ScriptedModel((_, _) async* {
          if (++turns == 1) {
            yield ModelResponse(
              calls: [
                ToolCall(
                  id: 'c',
                  name: 'list',
                  arguments: {'required': 'workspace', 'optional': null},
                ),
              ],
            );
          } else {
            yield ModelResponse(text: 'done');
          }
        }),
        tools: [
          AgentTool(
            name: 'list',
            description: 'list',
            parameters: schema,
            validate: (args) => args.containsKey('optional')
                ? 'optional was not removed'
                : null,
            execute: (call, _) async {
              received = call.arguments;
              return ToolResult('ok');
            },
          ),
        ],
      );
      final session = await manager.create();
      final done = await (await manager.prompt(session.id, 'list')).done;
      expect(done.status, RunStatus.completed);
      expect(received, {'required': 'workspace'});
      expect(done.history.expand((m) => m.calls).single.arguments, received);
    },
  );
}
