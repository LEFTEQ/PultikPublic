import CodeCore

// The code core's vocabulary under the names Pultík's code reads (workbench WP3b): the
// languages it highlights (path → language and which carry tags are the core's rules), the
// kinds a run paints and the runs themselves, in UTF-16 units. Packages/CodeCore/README.md.

/// A language the code canvas highlights; everything else draws as plain text.
typealias SyntaxLanguage = CodeCore.SyntaxLanguage
/// What a highlight run means on screen: the code theme's role it reads (`role`).
typealias TokenKind = CodeCore.TokenKind
/// A run of one kind inside a line, in UTF-16 units from the line's start.
typealias TokenRun = CodeCore.TokenRun
/// A parsed text's runs by line (0-based); a line with none is plain.
typealias LineTokens = CodeCore.LineTokens
