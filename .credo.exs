# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/"
        ],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/priv/",
          ~r"/native/"
        ]
      },
      plugins: [],
      requires: ["./credo/checks/case_on_boolean.ex", "./credo/checks/raw_in_heex.ex"],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # ── Consistency ──────────────────────────────────────────────
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          # ── Design ───────────────────────────────────────────────────
          # TagTODO and TagFIXME: keep enabled so TODOs show up in credo
          # output as reminders, but at low priority so they don't block CI.
          {Credo.Check.Design.TagTODO, [exit_status: 0]},
          {Credo.Check.Design.TagFIXME, []},

          # ── Readability ──────────────────────────────────────────────
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Readability.ModuleDoc, []},

          # ── Refactoring ──────────────────────────────────────────────
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 6]},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},

          # ── Warnings ─────────────────────────────────────────────────
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnsafeExec, []},

          # ── Third-party checks (credo_naming) ────────────────────────
          # Enforce module-name/filename consistency for the domain. Excluded:
          # the Phoenix web layer (controllers/live/components module names
          # legitimately omit their directory segment), Mix tasks (dotted
          # filenames like hooks.install.ex), and test files/support (Phoenix
          # test conventions) — these are directory conventions, not defects.
          {CredoNaming.Check.Consistency.ModuleFilename,
           [excluded_paths: [~r{lib/cake_web/}, ~r{lib/mix/}, ~r{test/}]]},

          # ── Third-party checks (jump_credo_checks) ───────────────────
          # Adopted the checks that fit Cake and fixed their findings
          # (AssertReceiveTimeout — moved to a global assert_receive_timeout;
          # LiveViewFormCanBeRehydrated — added the form id). The rest below are
          # zero-finding guardrails.
          #
          # Intentionally NOT enabled, because they misfire on legitimate Cake
          # patterns rather than surfacing real defects:
          #   - UndeclaredExternalResource: false-positives on `@spec`/`@type`
          #     that precede functions calling `File.read` at runtime (the check
          #     targets compile-time `@attr File.read!(...)`).
          #   - AvoidSocketAssignsInTest: flags UserAuth `on_mount`/plug unit
          #     tests that assert `socket.assigns.current_user` — but for an auth
          #     hook whose contract IS that assign, there is no rendered output
          #     to assert instead.
          #   - TestHasNoAssertions / VacuousTest: flag struct-contract tests
          #     (`@enforce_keys`, defaults) and the `apply/3` FunctionClauseError
          #     tests in pipelines_test (the check can't see `apply/3` as calling
          #     application code) — enabling them would force artificial rewrites.
          #   - ConditionalAssertion: flags legitimate `or`/`||` assertions — a
          #     property test where a label validly matches either of two
          #     formats, prompt-wording flexibility, and result-shape checks for
          #     non-deterministic jobs; pinning a single value isn't possible.
          {Jump.CredoChecks.SafeBinaryToTerm, []},
          {Jump.CredoChecks.WeakAssertion, []},
          {Jump.CredoChecks.UnusedLiveViewAssign, []},
          {Jump.CredoChecks.LiveViewFormCanBeRehydrated, []},
          {Jump.CredoChecks.AssertReceiveTimeout, []},
          {Jump.CredoChecks.AvoidLoggerConfigureInTest, []},
          {Jump.CredoChecks.AssertElementSelectorCanNeverFail, []},

          # ── Project-local checks (loaded via `requires` above) ───────
          {Cake.CredoChecks.CaseOnBoolean, []},
          {Cake.CredoChecks.RawInHeex, []}
        ],
        disabled: [{Credo.Check.Refactor.ModuleDependencies, []}]
      }
    }
  ]
}
