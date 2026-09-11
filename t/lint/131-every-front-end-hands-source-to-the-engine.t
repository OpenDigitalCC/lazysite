#!/usr/bin/perl
# SM797: every shipped front end hands the engine's source types to the engine.
#
# The engine refuses to hand out a page's markdown, a .url's upstream, a backup,
# a key or executable source (%STATIC_DENY), and renders a page asked for by its
# source name. None of that runs for a request the web server answers itself -
# and on a site with no ACL store and no content root, the web server answers
# every EXISTING file. The shipped Apache templates refused .brief and nothing
# else; nginx the same; so /about.md came back as markdown, front matter and
# all, from the front end on exactly the sites that had never protected
# anything.
#
# The remedy is one rule per front end that sends these types to the engine,
# whether or not the file exists: the answer is then the engine's everywhere. A
# list in eighteen places drifts, which is what this pins: every shipped config
# carries exactly the engine's list, less the SSI pair - a legacy .shtml page
# (SM133) is the front end's to expand, and Apache does, through mod_include.
#
# Read from source because the processor is module-free (ADR 0001) and its hash
# is a lexical; t/lint/127 does the same and pins the upload side.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper               qw(repo_root);
use Lazysite::DomainRewrites ();

my $root = repo_root();

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; return scalar <$fh> }

# Comments are stripped before matching, so a template cannot pass by describing
# the rule while lacking it.
sub code_of { return join "\n", grep { !/^\s*#/ } split /\n/, $_[0] }

# --- the engine's list, and what a front end carries ------------------------

my ($body) = slurp("$root/lazysite-processor.pl") =~ /BEGIN \{ %STATIC_DENY = map \{[^}]*\} qw\(([^)]*)\)/s;
ok( defined $body, 'found the engine\'s static-serve deny list' ) or BAIL_OUT('no %STATIC_DENY');
my @engine = grep { length } split /\s+/, $body;
cmp_ok( scalar @engine, '>', 10, 'and it is not empty - an empty list agrees with every front end' );

# The exception, named, and checked to name something real: an exclusion of a
# type the engine does not refuse would be a silent hole in the comparison.
my %SSI    = map { $_ => 1 } qw(shtml shtm);
my %engine = map { $_ => 1 } @engine;
ok( $engine{$_}, "the engine refuses .$_, so leaving it to the front end is a decision" ) for sort keys %SSI;

my @want = sort grep { !$SSI{$_} } @engine;

sub same_set {
    my ( $got, $what ) = @_;
    my %g       = map  { lc($_) => 1 } @$got;
    my %w       = map  { $_     => 1 } @want;
    my @missing = grep { !$g{$_} } @want;
    my @extra   = grep { !$w{$_} } sort keys %g;
    ok( !@missing && !@extra, "$what carries the engine's list" )
        or diag("missing: @missing\nextra: @extra");
    return;
}

# --- every shipped front end is checked or exempt by name -------------------

my %APACHE = (
    'installers/apache/vhost-cgi.conf.example'  => '/cgi-bin/lazysite-auth.pl',
    'installers/apache/vhost-fcgi.conf.example' => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-app.tpl'        => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-app.stpl'       => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-cgi.tpl'        => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-cgi.stpl'       => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-fcgi.tpl'       => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite-fcgi.stpl'      => '/cgi-bin/lazysite-auth.pl',
    'installers/hestia/lazysite.tpl'            => '/cgi-bin/lazysite-processor.pl',
    'installers/hestia/lazysite.stpl'           => '/cgi-bin/lazysite-processor.pl',
);
my @NGINX = qw(installers/nginx/vhost-cgi.conf.example installers/nginx/vhost-fcgi.conf.example);
my @PROXY = qw(installers/hestia/lazysite-proxy.tpl installers/hestia/lazysite-proxy.stpl);

# The one-rule configs send everything to the front door, which hands a 'static'
# decision to the processor - so %STATIC_DENY itself answers there, and there is
# no list to carry. t/lint/42 pins the two front doors' routing.
my %EXEMPT = map { $_ => 1 } qw(
    installers/apache/vhost-one-rule.conf.example
    installers/apache/vhost-one-rule-pool.conf.example
    installers/nginx/vhost-one-rule.conf.example
    installers/nginx/vhost-one-rule-pool.conf.example
);

{
    my @shipped = sort map { s{\A\Q$root/\E}{}r } (
        glob("$root/installers/apache/*.example"), glob("$root/installers/nginx/*.example"),
        glob("$root/installers/hestia/*.tpl"),     glob("$root/installers/hestia/*.stpl"),
    );
    my %checked     = map  { $_ => 1 } ( keys %APACHE, @NGINX, @PROXY );
    my @unaccounted = grep { !$checked{$_} && !$EXEMPT{$_} } @shipped;
    is_deeply( \@unaccounted, [],
        'every shipped front-end config is checked here or exempt by name - a template '
            . 'nobody listed is how .brief came to be the only type any of them refused' )
        or diag( join "\n  ", '', @unaccounted );
}

# --- Apache: one rewrite, to the engine, ahead of anything that serves -------

for my $rel ( sort keys %APACHE ) {
    my $code = code_of( slurp("$root/$rel") );
    subtest $rel => sub {
        my @rules = $code =~ m{^[ \t]*RewriteRule[ \t]+\\\.\(\?:([^)]*)\)\$[ \t]+(\S+)[ \t]+\[([^\]]*)\]}mg;
        is( scalar @rules, 3, 'one source hand-off rule' ) or return;
        my ( $list, $target, $flags ) = @rules;
        same_set( [ split /\|/, $list ], 'it' );
        is( $target, $APACHE{$rel}, "to $APACHE{$rel}, this template's engine entry" );
        like( $flags, qr/\bNC\b/, 'case-insensitive - ABOUT.MD is the same file on the wire' );
        like( $flags, qr/\bPT\b/, 'PT, so ScriptAlias maps the target (SM268)' );

        # The condition directly above it keeps the script surfaces out; without
        # it a CGI endpoint (.pl) or a DAV write (/dav/x.md) would be rerouted.
        like( $code, qr{RewriteCond[ \t]+%\{REQUEST_URI\}[ \t]+!\^/\(\?:cgi-bin\|dav\|lazysite\)\(\?:/\|\$\)\n[ \t]*RewriteRule[ \t]+\\\.\(\?:},
            'exempts /cgi-bin/, /dav and /lazysite/ on the line above' );

        # No surviving second list: the old .brief FilesMatch was a partial copy.
        unlike( $code, qr/<FilesMatch[^>]*brief/, 'and the .brief-only deny it replaces is gone' );

        # Ordering: every other RewriteRule ends in [L], so a hand-off after one
        # of them never runs for the files that rule serves.
        my $at = index( $code, 'RewriteRule \.(?:' );
        for my $other ( $code =~ m{^[ \t]*(RewriteRule[ \t]+(?!\\\.\(\?:)\S+[^\n]*\[[^\]]*\bL\b[^\]]*\])}mg ) {
            cmp_ok( $at, '<', index( $code, $other ), "ahead of '$other'" );
        }
    };
}

# --- nginx: a regex location to the engine that cannot catch a script ------

for my $rel (@NGINX) {
    my $code = code_of( slurp("$root/$rel") );
    subtest $rel => sub {
        my ( $look, $list, $inner )
            = $code =~ m#location[ \t]+~\*[ \t]+\^/\(\?!([^)]*\)[^)]*)\)\.\*\\\.\(\?:([^)]*)\)\$[ \t]*\{([^}]*)\}#;
        ok( defined $list, 'one source hand-off location' ) or return;
        same_set( [ split /\|/, $list ], 'it' );
        like( $inner, qr{try_files\s+/dev/null\s+\@lazysite;}, 'handing to the engine, whether or not the file exists' );
        like( $look, qr{\bcgi-bin/},        'never a /cgi-bin/ script' );
        like( $look, qr{\bdav\(\?:/\|\$\)}, 'never a /dav request' );
        unlike( $code, qr/location\s+~\s+\\\.brief\$/, 'and the .brief-only deny it replaces is gone' );
    };
}

# --- Hestia's proxy: nested ahead of the extension list ---------------------

for my $rel (@PROXY) {
    my $code = code_of( slurp("$root/$rel") );
    subtest $rel => sub {
        my ( $list, $inner ) = $code =~ m#location[ \t]+~\*[ \t]+\\\.\(\?:([^)]*)\)\$[ \t]*\{([^}]*)\}#;
        ok( defined $list, 'one source hand-off location' ) or return;
        same_set( [ split /\|/, $list ], 'it' );
        like( $inner, qr{proxy_pass\s+\S+;}, 'to the origin, which hands it to the engine' );

        # Nested regex locations are tried in order, and the extension list is
        # the operator's to edit; ahead of it, this holds whatever they add.
        my $loc_slash = index( $code, 'location / {' );
        my $handoff   = index( $code, 'location ~* \.(?:' );
        my $ext       = index( $code, '(%proxy_extensions%)' );
        ok( $loc_slash >= 0 && $loc_slash < $handoff && $handoff < $ext,
            'inside location /, ahead of the extension regex' );
    };
}

# --- the generated per-domain rules -----------------------------------------

same_set( \@Lazysite::DomainRewrites::SOURCE_EXT, 'Lazysite::DomainRewrites::SOURCE_EXT' );
{
    my $apache = Lazysite::DomainRewrites::apache_snippet( [ { host => 'alias.test', root => 'sites/foo' } ] );
    my ($serve) = $apache =~ m{(\# alias\.test: serve this domain's own static files\n(?:RewriteCond[^\n]*\n)+RewriteRule[^\n]*)};
    ok( defined $serve, 'the generated serve rule is found' );
    like( $serve // '', qr{RewriteCond %\{REQUEST_URI\} !\\\.\(\?:md\|[^)]*\)\$ \[NC\]},
        'and never serves a source type from a content root - wherever the operator put the block' );
}

done_testing();
