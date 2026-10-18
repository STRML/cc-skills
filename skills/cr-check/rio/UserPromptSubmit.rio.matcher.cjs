// Surfaces the cr-check skill when the user is talking about CodeRabbit reviews.
// rio UserPromptSubmit matcher — matchCount >= 1 surfaces the skill.
module.exports = function (context) {
  const prompt = (context.prompt || '').toLowerCase();

  const keywords = [
    'coderabbit',
    'code rabbit',      // users often type it as two words
    'rabbit review',
    'cr review',
    'cr-check',
    'cr check',
    'check cr',
    'coderabbit review',
    'coderabbit comment',
    'coderabbit finding',
    'check coderabbit',
    'what did coderabbit',
    'what did code rabbit',
    'bot review',        // CodeRabbit is "the bot" in the review loop
    'review bot',
    'address the review',
    'review findings',
  ];

  const matchCount = keywords.filter((k) => prompt.includes(k)).length;

  return {
    version: '2.0',
    matchCount: matchCount,
    type: 'skill',
  };
};
