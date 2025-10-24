import {
  complexModifications,
  map,
  rule,
  writeToProfile,
} from "https://deno.land/x/karabinerts@1.30.3/deno.ts";
import type {
  Modifier,
  Rule,
  RuleBuilder,
} from "https://deno.land/x/karabinerts@1.30.3/index.ts";

const PROFILE_SCRIPT_WRITES_TO = "Default";

const HYPER_MODIFIERS: Modifier[] = [
  "left_command",
  "left_shift",
  "left_option",
  "left_control",
];

export const rules = () => [
  rule("Caps Lock → Hyper").manipulators([
    map("caps_lock")
      .to({
        key_code: "left_shift",
        modifiers: ["left_command", "left_option", "left_control"],
      })
      .toIfAlone("escape"),
  ]),

  rule("Left arrow").manipulators([
    map("h", "left_command", ["left_option", "left_shift"]).to(
      "left_arrow",
    ),
  ]),

  rule("Down arrow").manipulators([
    map("j", "left_command", ["left_option", "left_shift"]).to(
      "down_arrow",
    ),
  ]),

  rule("Up arrow").manipulators([
    map("k", "left_command", ["left_option", "left_shift"]).to(
      "up_arrow",
    ),
  ]),

  rule("Right arrow").manipulators([
    map("l", "left_command", ["left_option", "left_shift"]).to(
      "right_arrow",
    ),
  ]),

  rule("Control tab forwards").manipulators([
    map("k", HYPER_MODIFIERS).to({
      key_code: "tab",
      modifiers: ["left_control"],
    }),
  ]),

  rule("Control tab backwards").manipulators([
    map("j", HYPER_MODIFIERS).to({
      key_code: "tab",
      modifiers: ["left_control", "left_shift"],
    }),
  ]),

  rule("Switch tab to right").manipulators([
    map("l", HYPER_MODIFIERS).to({
      key_code: "right_arrow",
      modifiers: ["left_option", "left_command"],
    }),
  ]),

  rule("Switch tab to left").manipulators([
    map("h", HYPER_MODIFIERS).to({
      key_code: "left_arrow",
      modifiers: ["left_option", "left_command"],
    }),
  ]),

  rule("Enter").manipulators([
    map("f", HYPER_MODIFIERS).to({
      key_code: "return_or_enter",
    }),
  ]),

  rule("Backspace").manipulators([
    map("d", HYPER_MODIFIERS).to({
      key_code: "delete_or_backspace",
    }),
  ]),
];

writeToProfile(PROFILE_SCRIPT_WRITES_TO, rules());

// to print out raw config:
function _printRawConfig(rules: Array<Rule | RuleBuilder>) {
  const config = complexModifications(rules).rules.reduce(
    (r, v) => ({
      description: r.description
        ? `${r.description}; ${v.description}`
        : v.description,
      manipulators: r.manipulators.concat(v.manipulators),
    }),
    { description: "", manipulators: [] },
  );
  console.log(JSON.stringify(config, null, 2));
}
