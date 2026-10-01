//
//  NVHTMLMarkdownTests.m
//  NotationTests
//

#import <XCTest/XCTest.h>
#import "NVHTMLMarkdown.h"

@interface NVHTMLMarkdownTests : XCTestCase
@end

@implementation NVHTMLMarkdownTests

- (NSString *)convert:(NSString *)html {
	return [NVHTMLMarkdown markdownFromHTML:html baseURL:nil articleOnly:NO];
}

- (void)assertHTML:(NSString *)html becomes:(NSString *)markdown {
	XCTAssertEqualObjects([self convert:html], markdown, @"%@", html);
}

- (void)testHeadings {
	[self assertHTML:@"<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h5>Five</h5><h6>Six</h6>"
			 becomes:@"# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n"];
}

- (void)testParagraphsAndContainers {
	[self assertHTML:@"<p>First</p><p>Second</p>" becomes:@"First\n\nSecond\n"];
	[self assertHTML:@"<div>Alpha</div><section>Beta</section>" becomes:@"Alpha\n\nBeta\n"];
	[self assertHTML:@"<div>Intro <p>inside</p> outro</div>" becomes:@"Intro\n\ninside\n\noutro\n"];
}

- (void)testLineBreak {
	[self assertHTML:@"<p>line one<br>line two</p>" becomes:@"line one  \nline two\n"];
}

- (void)testStrongAndEmphasis {
	[self assertHTML:@"<p><strong>bold</strong> and <b>bold</b> and <em>it</em> and <i>it</i></p>" becomes:@"**bold** and **bold** and *it* and *it*\n"];
	[self assertHTML:@"<p>a<b> spaced </b>b</p>" becomes:@"a **spaced** b\n"];
}

- (void)testInlineCode {
	[self assertHTML:@"<p>run <code>make test</code> now</p>" becomes:@"run `make test` now\n"];
	[self assertHTML:@"<p><code>a`b</code></p>" becomes:@"``a`b``\n"];
}

- (void)testPreWithAndWithoutCode {
	[self assertHTML:@"<pre>if (a &lt; b) {\n    x &amp;= 1;\n}</pre>" becomes:@"```\nif (a < b) {\n    x &= 1;\n}\n```\n"];
	[self assertHTML:@"<pre><code class=\"c\">int *p = 0;\n  return;\n</code></pre>" becomes:@"```\nint *p = 0;\n  return;\n```\n"];
	[self assertHTML:@"<pre>\nfirst\n\nsecond</pre>" becomes:@"```\nfirst\n\nsecond\n```\n"];
	[self assertHTML:@"<pre>```\nx</pre>" becomes:@"````\n```\nx\n````\n"];
}

- (void)testLinks {
	[self assertHTML:@"<p><a href=\"http://example.com/a\">site</a></p>" becomes:@"[site](http://example.com/a)\n"];
	[self assertHTML:@"<p><a href=\"http://example.com/a\"></a></p>" becomes:@"[http://example.com/a](http://example.com/a)\n"];
	[self assertHTML:@"<p><a href=\"javascript:void(0)\">click</a></p>" becomes:@"click\n"];
	[self assertHTML:@"<p><a href=\"#top\">top</a></p>" becomes:@"top\n"];
	[self assertHTML:@"<p><a href=\"http://example.com/a_(b)\">x</a></p>" becomes:@"[x](http://example.com/a_%28b%29)\n"];
}

- (void)testRelativeLinksAndImagesResolveAgainstBaseURL {
	NSURL *base = [NSURL URLWithString:@"http://example.com/blog/post.html"];
	NSString *html = @"<p><a href=\"../about\">About</a> <a href=\"/root\">Root</a> <a href=\"next.html\">Next</a> <img src=\"img/a.png\" alt=\"pic\"></p>";
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:html baseURL:base articleOnly:NO],
						  @"[About](http://example.com/about) [Root](http://example.com/root) [Next](http://example.com/blog/next.html) ![pic](http://example.com/blog/img/a.png)\n");
}

- (void)testImages {
	[self assertHTML:@"<p><img src=\"http://example.com/a.png\" alt=\"An [odd] pic\"></p>" becomes:@"![An odd pic](http://example.com/a.png)\n"];
	[self assertHTML:@"<p><img src=\"data:image/png;base64,AAAA\" alt=\"x\">text</p>" becomes:@"text\n"];
	[self assertHTML:@"<p><a href=\"http://example.com\"><img src=\"http://example.com/i.png\" alt=\"i\"></a></p>"
			 becomes:@"[![i](http://example.com/i.png)](http://example.com)\n"];
}

- (void)testLists {
	[self assertHTML:@"<ul><li>one</li><li>two</li></ul>" becomes:@"- one\n- two\n"];
	[self assertHTML:@"<ol><li>one</li><li>two</li><li>three</li></ol>" becomes:@"1. one\n2. two\n3. three\n"];
	[self assertHTML:@"<p>before</p><ul><li>x</li></ul><p>after</p>" becomes:@"before\n\n- x\n\nafter\n"];
}

- (void)testNestedLists {
	[self assertHTML:@"<ul><li>one<ul><li>inner a</li><li>inner b<ol><li>deep</li></ol></li></ul></li><li>two</li></ul>"
			 becomes:@"- one\n    - inner a\n    - inner b\n        1. deep\n- two\n"];
}

- (void)testListItemWithParagraphs {
	[self assertHTML:@"<ul><li><p>First para</p><p>Second para</p></li><li>next</li></ul>"
			 becomes:@"- First para\n\n    Second para\n- next\n"];
}

- (void)testBlockquote {
	[self assertHTML:@"<blockquote>quoted</blockquote>" becomes:@"> quoted\n"];
	[self assertHTML:@"<blockquote><p>one</p><p>two</p></blockquote>" becomes:@"> one\n>\n> two\n"];
}

- (void)testNestedBlockquote {
	[self assertHTML:@"<blockquote><p>outer</p><blockquote><p>inner</p></blockquote></blockquote>" becomes:@"> outer\n>\n> > inner\n"];
}

- (void)testHorizontalRule {
	[self assertHTML:@"<p>above</p><hr><p>below</p>" becomes:@"above\n\n---\n\nbelow\n"];
}

- (void)testTables {
	[self assertHTML:@"<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>" becomes:@"a | b\nc | d\n"];
	[self assertHTML:@"<table><thead><tr><th>Key</th><th>Action</th></tr></thead><tbody><tr><td>x</td><td>a | b</td></tr></tbody></table>"
			 becomes:@"Key | Action\n--- | ---\nx | a \\| b\n"];
}

- (void)testWhitespaceCollapses {
	[self assertHTML:@"<p>  lots   of\n\t space \u00a0 here  </p>" becomes:@"lots of space here\n"];
	[self assertHTML:@"<p>a</p>\n\n\n<p>b</p>" becomes:@"a\n\nb\n"];
}

- (void)testScriptStyleAndHeadDropped {
	[self assertHTML:@"<html><head><title>Title</title><style>p{color:red}</style><script>var a = '<p>no</p>';</script></head>"
	 @"<body><p>kept</p><script>alert(1)</script><style>.x{}</style><noscript>enable js</noscript><template><p>tpl</p></template></body></html>"
			 becomes:@"kept\n"];
}

- (void)testEntities {
	[self assertHTML:@"<p>Fish &amp; chips&nbsp;and Don&#8217;t &lt;b&gt; &copy;</p>" becomes:@"Fish & chips and Don\u2019t <b> \u00a9\n"];
}

- (void)testEscapesMarkdownSyntaxInText {
	[self assertHTML:@"<p>2 * 3 and `tick` and snake_case and _lead</p>" becomes:@"2 \\* 3 and \\`tick\\` and snake_case and \\_lead\n"];
	[self assertHTML:@"<p># not a heading</p><p>&gt; not a quote</p><p>- not a list</p><p>+ plus</p><p>1. not numbered</p>"
			 becomes:@"\\# not a heading\n\n\\> not a quote\n\n\\- not a list\n\n\\+ plus\n\n1\\. not numbered\n"];
	[self assertHTML:@"<p>Version 1.5 costs -5 dollars. Done.</p>" becomes:@"Version 1.5 costs -5 dollars. Done.\n"];
}

- (void)testArticleOnlyKeepsArticleAndDropsChrome {
	NSString *html = @"<html><body><header>Site</header><nav><a href=\"/x\">Nav</a></nav>"
	@"<article><h1>Story</h1><p>Body text.</p></article><aside>Related</aside><footer>Copyright</footer></body></html>";
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:html baseURL:nil articleOnly:YES], @"# Story\n\nBody text.\n");
	XCTAssertTrue([[NVHTMLMarkdown markdownFromHTML:html baseURL:nil articleOnly:NO] containsString:@"Copyright"]);
}

- (void)testArticleOnlyFallsBackToMainThenBody {
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:@"<body><nav>Menu</nav><main><p>Main stuff</p></main><footer>Foot</footer></body>"
												   baseURL:nil articleOnly:YES], @"Main stuff\n");
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:@"<body><nav>Menu</nav><form>Search</form><div>Real content</div><aside>Side</aside><footer>Foot</footer></body>"
												   baseURL:nil articleOnly:YES], @"Real content\n");
}

- (void)testArticleOnlyPicksLargestArticle {
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:@"<article>tiny</article><article><p>The much longer article</p></article>"
												   baseURL:nil articleOnly:YES], @"The much longer article\n");
}

- (void)testMessyHTML {
	[self assertHTML:@"<P>one<P>two <B>bold <I>both</B> after" becomes:@"one\n\ntwo **bold *both* after**\n"];
	[self assertHTML:@"<UL><LI>a<LI>b</UL>" becomes:@"- a\n- b\n"];
	[self assertHTML:@"<DIV><H2>Head</H2><A HREF=\"http://example.com\">link</A></DIV>" becomes:@"## Head\n\n[link](http://example.com)\n"];
	[self assertHTML:@"just a fragment, no tags" becomes:@"just a fragment, no tags\n"];
}

- (void)testRealisticPage {
	NSString *html = @"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Post</title></head><body>"
	@"<nav><a href=\"/\">Home</a></nav><article><h1>Hello</h1><p>Some <em>text</em>, a <a href=\"/more\">link</a>.</p>"
	@"<ul><li>One</li><li>Two</li></ul><pre><code>run()</code></pre></article><footer>(c)</footer></body></html>";
	NSString *expected = @"# Hello\n\nSome *text*, a [link](http://example.com/more).\n\n- One\n- Two\n\n```\nrun()\n```\n";
	XCTAssertEqualObjects([NVHTMLMarkdown markdownFromHTML:html baseURL:[NSURL URLWithString:@"http://example.com/post"] articleOnly:YES], expected);
}

- (void)testEmptyAndGarbageInput {
	XCTAssertEqualObjects([self convert:@""], @"");
	XCTAssertEqualObjects([self convert:nil], @"");
	XCTAssertEqualObjects([self convert:@"   \n  "], @"");
	XCTAssertEqualObjects([self convert:@"<html><body></body></html>"], @"");
	XCTAssertNotNil([self convert:@"<<<>>> </ </p <a href= <b"]);
	XCTAssertNotNil([self convert:@"\x01\x02 binary \ufffd junk <p"]);
	XCTAssertNotNil([NVHTMLMarkdown markdownFromHTML:@"<a href=\"::bad url::\">x</a>" baseURL:[NSURL URLWithString:@"http://example.com"] articleOnly:YES]);
}

@end
