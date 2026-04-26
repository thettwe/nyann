// nyann template v1 — commitlint config
// Enforces Conventional Commits. Extend from @commitlint/config-conventional
// so users can layer project-specific rules in their own file later.

module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      2,
      'always',
      [
        'feat',
        'fix',
        'chore',
        'docs',
        'refactor',
        'test',
        'perf',
        'ci',
        'build',
        'style',
        'revert',
      ],
    ],
  },
};
