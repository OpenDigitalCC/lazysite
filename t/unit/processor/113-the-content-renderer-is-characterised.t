#!/usr/bin/perl
# SM1012: render_content's observable output, recorded, so a split of the sub
# can be shown to change none of it.
#
# render_content is the template pass every page crosses (render.pm). Ruled
# 2026-10-12: it is split after _render_form, behind a characterisation test
# written first and committed alone, its record committed beside it and
# regenerated only on a ruled change (SM1012 Q1, Q4).
#
# THE CASES are written here: page bodies that exercise each phase of the sub -
# the stash, the code-block protection and its restore, the TAGS guard, a
# template error, a render that multiplies a protected block, the before_render
# hook, the language and the manager facts - under five request contexts
# (anonymous; a member; a manager; a manager previewing a layout and theme; a
# payment-gated page) and two hosts (the primary and a language alias). The three
# branches the 0.15.5 gate's coverage left unreached in render_content each have
# a case (%BRANCH): an editor rooted at one domain (159), a placeholder the
# template rewrote so that no block answers it (488), and a Template object that
# cannot be built (107). That last one does not reach the branch: when the
# compile directory cannot be made, Template->new DIES (Template::Provider's
# mkdir) rather than returning false, so `or do { umask ...; die }` is not what
# runs - and the umask _cache_umask set is not restored. The record says so
# (umask_after 0002 for that case, 0027 for every other); no input was found
# that makes Template->new return false with these fixed options.
#
# WHAT IS RECORDED per case: the body; the stash ($vars) as data, code refs as
# "CODE" and objects as their class; $RESPONSE_LANG; every log_event call; the
# die message if it died; the umask it left; and any warning, which fails the
# case. Masked: the fixture's temporary paths, `year` (the clock), and the
# per-render placeholder key (random by design, SM967) where a case makes it
# reach the output.
#
#   LAZYSITE_CHARACTERISE=write prove -l t/unit/processor/113-*.t   # re-record
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use JSON::PP       ();
use Scalar::Util   qw(blessed);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir);

no warnings 'once';    # the processor's globals are named here once each

my $RECORD = "$FindBin::Bin/113-the-content-renderer-is-characterised.json";
my $WRITE  = ( $ENV{LAZYSITE_CHARACTERISE} // '' ) eq 'write';
my $JSON   = JSON::PP->new->utf8->canonical->pretty;

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# --- the fixture site, built before the processor loads ---

my $docroot = site_tempdir();
my $tmproot = dirname( dirname($docroot) );
make_path( "$docroot/lazysite/auth", "$docroot/lazysite/forms", "$docroot/fr" );
spit( "$docroot/lazysite/lazysite.conf", <<'CONF' );
site_name: Char Site
site_url: https://char.example
lang: en
lang_group: g1
alias_hosts: fr.char.example
alias.fr.char.example.site_name: Site FR
alias.fr.char.example.site_url: https://fr.char.example
alias.fr.char.example.lang: fr
alias.fr.char.example.lang_group: g1
alias.fr.char.example.content_root: fr
alias.fr.char.example.allowed_groups: fr-editors
CONF
spit( "$docroot/lazysite/auth/groups", "admins: alice\nfr-editors: bob\nmembers: carol\n" );
spit( "$docroot/lazysite/auth/groups-settings.json",
    '{"admins":{"ui":1,"manage_users":1,"manage_config":1,"manage_domains":1},'
        . '"fr-editors":{"ui":1,"manage_content":1},"members":{}}' );
spit( "$docroot/index.md",    "---\ntitle: Home\n---\nHome.\n" );
spit( "$docroot/about.md",    "---\ntitle: About\n---\nAbout.\n" );
spit( "$docroot/fr/index.md", "---\ntitle: Accueil\n---\nAccueil.\n" );

$ENV{HTTP_HOST}   = 'char.example';
$ENV{REMOTE_ADDR} = '203.0.113.7';
load_processor($docroot);

my %BRANCH = (
    'render.pm:107 a Template object that cannot be built (it dies instead)' => 'tt-compile-dir-is-a-file',
    'render.pm:159 an editor rooted at one domain' => 'member-one-scope',
    'render.pm:488 a placeholder no block answers is kept' => 'placeholder-rewritten-by-the-template',
);

my %CONTEXT = (
    anon => {},
    member => { auth => { auth_user => 'bob', auth_name => 'Bob <b>', auth_email => 'bob@example.org', auth_groups => ['fr-editors'] } },
    member2 => { auth => { auth_user => 'carol', auth_name => 'Carol', auth_email => '', auth_groups => 'members' } },
    manager => { auth => { auth_user => 'alice', auth_name => 'Alice', auth_email => 'alice@example.org', auth_groups => ['admins'] } },
    preview => {
        auth => { auth_user => 'alice', auth_name => 'Alice', auth_email => 'alice@example.org', auth_groups => ['admins'] },
        preview => { layout => 'plain', theme => 'dusk' },
    },
    payment => {
        payment => {
            payment_required => 0, payment_amount => '5.00', payment_currency => 'GBP',
            payment_address => 'addr', payment_paid => 1, payment_payer => 'p<1>', payment_bypassed => 0,
        },
    },
);

my %HOOK = (
    none => undef,
    stamps => sub { my ($v) = @_; $v->{hooked} = 'yes'; $v->{site_name} = 'Hooked <i>'; return },
);

sub normal {
    my ($d) = @_;
    return $d unless defined $d;
    if ( blessed $d ) { return 'OBJECT(' . ref($d) . ')' }
    my $r = ref $d;
    return [ map { normal($_) } @$d ]                        if $r eq 'ARRAY';
    return { map { ( $_ => normal( $d->{$_} ) ) } keys %$d } if $r eq 'HASH';
    return 'CODE'                                            if $r eq 'CODE';
    return "REF($r)"                                         if $r;
    ( my $s = $d ) =~ s/\Q$docroot\E/DOCROOT/g;
    $s             =~ s/\Q$tmproot\E/TMP/g;
    $s             =~ s/CODEBLOCK[0-9a-f]{16}_/CODEBLOCKKEY_/g;
    return $s;
}

sub run_case {
    my ($c) = @_;
    my ( @log, @warn );
    no warnings 'redefine';
    local *main::log_event = sub {
        my ( $level, $context, $message, %extra ) = @_;
        push @log, { level => $level, context => $context, message => $message, extra => \%extra };
        return;
    };
    local $SIG{__WARN__} = sub { push @warn, $_[0] };
    my $ctx = $CONTEXT{ $c->{context} } or die "no context $c->{context}";
    local %main::AUTH_CONTEXT    = %{ $ctx->{auth}    || {} };
    local %main::PAYMENT_CONTEXT = %{ $ctx->{payment} || {} };
    local %main::PREVIEW_CONTEXT = %{ $ctx->{preview} || {} };
    local $main::RESPONSE_LANG   = 'unset';
    local $main::TT_COMPILE_DIR = $c->{tt_dir} ? "$docroot/$c->{tt_dir}" : $main::TT_COMPILE_DIR;
    local $ENV{HTTP_HOST}    = $c->{host} // 'char.example';
    local $ENV{REDIRECT_URL} = $c->{uri}  // '/page';
    my %meta = %{ $c->{meta} };
    $meta{_md_path} = "$docroot/$meta{_md_path}" if defined $meta{_md_path};
    my ( $body, $vars );
    # Files whose presence the stash reports, made for this case only.
    spit( "$docroot/$_", "x\n" ) for @{ $c->{files} || [] };
    my $umask = umask 027;    # a known umask, so what the sub leaves is visible
    my $ok    = eval {
        ( $body, $vars ) = main::render_content( \%meta, $c->{body}, $c->{query}, $HOOK{ $c->{hook} // 'none' } );
        1;
    };
    my $after = umask $umask;
    unlink "$docroot/$_" for @{ $c->{files} || [] };
    my $died = $ok ? undef : $@;
    my $v    = normal($vars);
    $v->{year} = 'YEAR' if ref $v eq 'HASH' && exists $v->{year};
    return {
        body        => normal($body),
        vars        => $v,
        lang        => $main::RESPONSE_LANG,
        log         => normal( \@log ),
        died        => normal($died),
        umask_after => sprintf( '%04o', $after ),
        warnings    => \@warn,
    };
}

# --- the cases ---

sub cases {
    my @c;
    my $add = sub {
        my ( $id, $body, %o ) = @_;
        push @c, {
            id      => $id,
            body    => $body,
            meta    => $o{meta} // { title => 'A page' },
            query   => $o{query},
            context => $o{context} // 'anon',
            ( map { exists $o{$_} ? ( $_ => $o{$_} ) : () } qw(host uri hook tt_dir files) ),
        };
    };
    my $stash = '<p>[% site_name %] | [% page_title %] | [% page_subtitle %] | [% auth_user %]'
        . ' | [% editor %] | [% site_lang %] [% page_lang %] | [% scope_root %] | [% request_uri %]</p>';

    for my $ctx (qw(anon member member2 manager preview payment)) {
        $add->( "stash-$ctx", $stash, context => $ctx,
            meta => { title => 'Title & <b>bold</b>', subtitle => 'Sub "q"', _md_path => 'about.md' } );
    }
    $add->( 'member-one-scope', '[% scope_root %]|[% home_domain %]|[% dav_scopes %]', context => 'member' );
    $add->( 'manager-every-scope', '[% scope_root %]|[% home_domain %]|[% dav_scopes %]', context => 'manager' );
    $add->( 'manager-caps', '[% FOREACH k IN manager_caps.keys.sort %][% k %]=[% manager_caps.$k %] [% END %]',
        context => 'manager' );
    $add->( 'alias-host-french', $stash . '[% FOREACH l IN languages %]{[% l.lang %] [% l.url %] [% l.current %] [% l.exists %]}[% END %]',
        host => 'fr.char.example', uri => '/', meta => { title => 'Accueil' } );
    $add->( 'language-set-on-the-primary', '[% FOREACH l IN languages %]{[% l.lang %] [% l.url %] [% l.current %] [% l.exists %]}[% END %]',
        uri => '/about?x=1' );
    $add->( 'page-lang-is-sanitised', '[% page_lang %]', meta => { title => 'L', lang => qq{fr"><script>\r\n} } );
    $add->( 'page-lang-sanitised-to-nothing', '[% page_lang %]', meta => { title => 'L', lang => '<>' } );
    $add->( 'meta-extras', '[% page_author %]|[% page_custom %]|[% page_meta_desc %]|[% page_meta_title %]|[% page_modified %]',
        meta => {
            title => 'T', author => 'A <x>', custom => 'v<1>', meta_desc => 'D & d', meta_title => 'MT',
            page_modified => '2026-01-02', page_modified_iso => '2026-01-02T00:00:00Z', tt_x => 'hidden', _y => 'hidden',
            ref_val => [1],
        } );
    $add->( 'tt-page-var', '[% greeting %] [% n %]', meta => { title => 'T', tt_page_var => { greeting => 'hello', n => '3' } } );
    $add->( 'sections', '[% FOREACH s IN sections %][% s.title %];[% END %]',
        meta => { title => 'S', sections => [ { title => 'One' }, { title => 'Two' } ] } );
    $add->( 'query-is-escaped', '[% query.q %]|[% params.q %]|[% query.n %]',
        query => { q => q{a<b>&"c' [% x %]}, n => '7' } );
    $add->( 'no-query-given', '[% query.q %]' );
    $add->( 'code-blocks-protected',
        '<pre><code class="x">[% site_name %] CODEBLOCK_0_END</code></pre> <code>[% page_title %]</code> [% site_name %]' );
    $add->( 'a-code-span-in-a-loop', '[% FOREACH i IN [1, 2, 3] %]<code>[% i %]</code>[% END %]' );
    $add->( 'a-code-span-in-a-loop-twice', '<code>a</code>[% FOREACH i IN [1, 2] %]<code>b</code>[% END %]' );
    $add->( 'placeholder-rewritten-by-the-template',
        "[% FILTER replace('_0_END', '_9_END') %]<code>z</code>[% END %]" );
    $add->( 'author-writes-a-placeholder', 'CODEBLOCK_7_END <code>c</code>' );
    $add->( 'tags-are-ignored',  "[% TAGS {{ }} %]{{ site_name }} [% site_name %]" );
    $add->( 'tags-with-a-chomp', "[%- TAGS <+ +> %]<+ site_name +>" );
    $add->( 'a-template-error-renders-raw', '<p>[% IF %]</p> <code>kept</code>' );
    $add->( 'the-hook-sees-the-stash', '[% hooked %]|[% site_name %]', hook => 'stamps' );
    $add->( 'the-url-safe-filter',            "[% 'a b/c?d=e' | url_safe %]" );
    $add->( 'eval-perl-is-off',               '[% PERL %]print 1;[% END %]' );
    $add->( 'an-absolute-include-is-refused', "[% INCLUDE '/etc/hostname' %]" );
    $add->( 'empty-body',                     '' );
    $add->( 'smtp-and-search-present', '[% smtp_configured %] [% search_enabled %]',
        files => [ 'lazysite/forms/smtp.conf', 'search-results.md' ] );
    $add->( 'search-by-url-page', '[% search_enabled %]', files => ['search-results.url'] );
    $add->( 'tt-compile-dir-is-a-file', '[% site_name %]', tt_dir => 'index.md/tt' );
    return @c;
}

# --- record, or check ---

if ($WRITE) {
    my @cases = cases();
    my %ids;
    $ids{ $_->{id} }++ and die "duplicate case id $_->{id}\n" for @cases;
    for my $c (@cases) {
        my $got = run_case($c);
        die "case $c->{id} warned: @{ $got->{warnings} }" if @{ $got->{warnings} };
        delete $got->{warnings};
        $c->{got} = $got;
    }
    open my $fh, '>', $RECORD or die "$RECORD: $!";
    print {$fh} $JSON->encode( { cases => \@cases } );
    close $fh;
    diag( 'recorded ' . scalar(@cases) . " cases to $RECORD" );

    # Checked in a fresh process, not this one: the site variables are cached
    # per process, and the first case logs what the first resolution says.
    pass('recorded; run again without LAZYSITE_CHARACTERISE to check');
    done_testing();
    exit 0;
}

open my $rh, '<', $RECORD or die "$RECORD: $! (record it: LAZYSITE_CHARACTERISE=write)";
my $record = $JSON->decode( do { local $/; <$rh> } );
close $rh;
my @cases = @{ $record->{cases} };

cmp_ok( scalar @cases, '>=', 30, 'the record holds the cases' );
my %have = map { $_->{id} => 1 } @cases;
for my $branch ( sort keys %BRANCH ) {
    ok( $have{ $BRANCH{$branch} }, "a case reaches $branch ($BRANCH{$branch})" );
}

for my $c (@cases) {
    my $got = run_case($c);
    my $id  = $c->{id};
    is_deeply( $got->{warnings}, [], "$id: no warning" );
    is( $got->{body}, $c->{got}{body}, "$id: the body" );
    is_deeply( $got->{vars}, $c->{got}{vars}, "$id: the stash" );
    is( $got->{lang}, $c->{got}{lang}, "$id: the response language" );
    is_deeply( $got->{log}, $c->{got}{log}, "$id: what it logged" );
    is( $got->{died},        $c->{got}{died},        "$id: how it died, if it did" );
    is( $got->{umask_after}, $c->{got}{umask_after}, "$id: the umask it left" );
}

done_testing();
