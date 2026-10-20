#!/usr/bin/perl
# SM1169 (SM1082 C1): A POOLED WORKER CARRIES NOTHING ABOUT A PERSON FROM ONE
# REQUEST TO THE NEXT, AND THE POOL'S PARENT LOADS WHAT ITS WORKERS USE.
#
# THE CLASS (SM973). A pooled worker (SM142) serves up to 500 requests in one
# process. A variable declared at file scope - `my`, or package `our` - outlives
# the request that filled it. SM973 was $ACL_MAP_CACHE: parsed once, kept for the
# worker's life, so a file protected afterwards was still served. The same shape
# with a user, a cookie, an address or a form value in it is data carried from
# one visitor to the next, and nothing in a test of ONE request can show it.
#
# WHAT THIS HOLDS. Every file-scope variable in the code a pooled worker keeps
# resident is one of three things, and a fourth thing fails here:
#
#   CONSTANT   it is initialised from literals and nothing in the resident code
#              assigns to it again (found by this test, not declared - a constant
#              that gains an assignment stops being one and is then listed below);
#   RESET      the request boundary clears it. The test reads the named reset
#              sub (reset_request_state / handle_one_request in the processor)
#              and fails if the variable is not in it;
#   EXEMPT     it holds something that is not about a request, with the reason
#              written beside it: configuration read once, a cache keyed on what
#              it caches, a process setting.
#
# A variable that is none of these - a new `my %seen_by_user;` - fails, naming
# the file, the line and the variable. A table entry that matches no declaration
# fails too, so the lists cannot go stale.
#
# THE RESIDENT CODE is lazysite-processor.pl, its parts, and the Lazysite::
# modules reached from them: the ones the processor loads on first use
# (@POOL_PRELOAD in lazysite-processor/front-door.pm, which the pool's parent
# loads before it forks) and everything those `use` or `require`. The set is
# computed here, so a module pulled in later is in scope the day it is.
#
# A source scan, not PPI (not a dependency): file scope is "outside every sub",
# found by counting braces over the code with strings, comments, pod and
# heredocs removed. t/lint/215 makes the same trade for the script's own `my`s.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "$f: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# --- the scan --------------------------------------------------------------

# The code of a file as a list of [line_number, text], with pod, whole-line and
# trailing comments, heredoc bodies and string literals removed, so that braces
# and `my` can be read from what is left. A string keeps a placeholder ("S") so
# the shape of a statement survives.
sub code_lines {
    my ($text) = @_;
    my @out;
    my ( $in_pod, $heredoc ) = ( 0, undef );
    my $n = 0;
    for my $raw ( split /\n/, $text, -1 ) {
        $n++;
        last if $raw =~ /^__(?:END|DATA)__\b/;
        if ($in_pod) { $in_pod = 0 if $raw =~ /^=cut\b/; next }
        if ( $raw =~ /^=[a-zA-Z]/ ) { $in_pod = 1; next }
        if ( defined $heredoc ) {
            my $t = $raw;
            $t =~ s/^\s+// if $heredoc->{indent};
            $heredoc = undef if $t eq $heredoc->{tag};
            next;
        }
        my $l = $raw;
        next if $l =~ /^\s*#/;
        my $hd;
        if ( $l =~ /<<(~?)(?:'([A-Z_][A-Z0-9_]*)'|"([A-Z_][A-Z0-9_]*)"|([A-Z_][A-Z0-9_]*))/ ) {
            $hd = { tag => $2 // $3 // $4, indent => $1 ? 1 : 0 };
        }
        # string literals first, so a # or a brace inside one is not read as code
        $l =~ s/'(?:[^'\\]|\\.)*'/S/g;
        # an interpolating string is not a literal: it keeps a $ that says so (SV)
        $l =~ s/"((?:[^"\\]|\\.)*)"/ my $s = $1; $s =~ m{(?<!\\)[\$\@]\w} ? '$INTERPOLATED' : 'S' /ge;
        $l =~ s/\s+#.*$//;
        $heredoc = $hd if $hd;
        push @out, [ $n, $l ];
    }
    return @out;
}

# Every declaration made outside any sub: [ line, kind, sigil.name, statement ].
# kind is my | our. The statement is the code from the declaration to its `;`,
# strings as S.
sub file_scope_decls {
    my ($text) = @_;
    my @lines = code_lines($text);
    # A stack of blocks. A sub's own block is skipped. A `my` in any other block
    # is scoped to it and dies with it, unless the block holds a sub (the bare
    # block idiom: `{ my %cache; sub f { ... } }`), whose closure keeps it alive.
    my @stack = ( { sub => 0, has_sub => 1, decls => [] } );    # file level: always kept
    my @decls;
    my $pending_sub = 0;
    for ( my $i = 0 ; $i < @lines ; $i++ ) {
        my ( $n, $l ) = @{ $lines[$i] };
        while ( $l =~ /\G(.*?)(\bsub\b|[{}]|\b(?:my|our)\b)/gc ) {
            my ( $before, $tok ) = ( $1, $2 );
            if ( $tok eq 'sub' ) {
                $pending_sub = 1;
                $_->{has_sub} = 1 for @stack;
            }
            elsif ( $tok eq '{' ) {
                push @stack, { sub => $pending_sub, has_sub => 0, decls => [] };
                $pending_sub = 0;
            }
            elsif ( $tok eq '}' ) {
                my $b = pop @stack;
                last unless @stack;
                push @decls, @{ $b->{decls} } if !$b->{sub} && $b->{has_sub};
                $stack[-1]{decls} = $stack[-1]{decls};
            }
            else {
                next if grep { $_->{sub} } @stack;
                next if $before =~ /\b(?:for|foreach)\s*\z/;    # a loop variable
                my $from = pos($l) - length($tok);
                my $stmt = substr( $l, $from );
                my $j    = $i;
                while ( $stmt !~ /;/ && $j + 1 < @lines ) {
                    $j++;
                    $stmt .= ' ' . $lines[$j][1];
                }
                push @{ $stack[-1]{decls} }, [ $n, $tok, $stmt ];
            }
        }
        $pending_sub = 0 if $l =~ /;\s*\z/ && $pending_sub;
    }
    push @decls, @{ $stack[0]{decls} };
    # split each statement into its variables
    my @vars;
    for my $d (@decls) {
        my ( $n, $kind, $stmt ) = @$d;
        # `my ($a, $b)` / `our ($a, @b)` / `my $x` / `our %h`
        my ( $names, $rest );
        if ( $stmt =~ /\A(?:my|our)\s*\(([^)]*)\)\s*(.*)\z/s ) { ( $names, $rest ) = ( $1, $2 ) }
        elsif ( $stmt =~ /\A(?:my|our)\s+([\$\@%]\w+)\s*(.*)\z/s ) { ( $names, $rest ) = ( $1, $2 ) }
        else { next }
        my $list = $stmt =~ /\A(?:my|our)\s*\(/ ? 1 : 0;
        for my $v ( $names =~ /([\$\@%]\w+)/g ) {
            push @vars, { line => $n, kind => $kind, var => $v, stmt => $stmt, rest => $rest, list => $list };
        }
    }
    return @vars;
}

# Is the initialiser made of literals only? "$rest" is what follows the
# declaration. No initialiser is NOT a literal (an empty variable is exactly the
# kind that gets filled later).
sub literal_init {
    my ($rest) = @_;
    return 0 unless $rest =~ /\A=(?!=)\s*(.*?);?\s*\z/s;
    my $rhs = $1;
    return 0 unless length $rhs;
    return 0 if $rhs =~ /\bundef\b/;    # an empty slot, for later
    for my $q (qw(qw qr)) {
        $rhs =~ s{\b$q\s*(?:/(?:\\.|[^/\\])*/|\{(?:\\.|[^{}\\]|\{[^{}]*\})*\}|\((?:\\.|[^()\\]|\([^()]*\))*\)|\[(?:\\.|[^\[\]\\])*\]|\|(?:\\.|[^|\\])*\||!(?:\\.|[^!\\])*!)[a-z]*}{ $q }gs;
    }
    return 0 if $rhs =~ /\bS\b.*\$\w/ && 0;
    # a string that interpolated a variable is not a literal: code_lines made it S
    # and lost that, so interpolation is checked on the raw statement separately.
    $rhs =~ s/\b(?:qw|qr|map|grep|sort|sub|do)\b/ /g;
    $rhs =~ s/\$_\b|\$a\b|\$b\b|\$[0-9]\b//g;
    $rhs =~ s/[=,;(){}\[\]<>:?.+\-*\/x|!&]/ /g;
    $rhs =~ s/\bS\b/ /g;
    $rhs =~ s/\b\d[\d_.]*\b/ /g;
    $rhs =~ s/\b[A-Za-z_]\w*(?=\s*(?:=>|\s|$))/ /g;    # barewords (hash keys, constants)
    return $rhs =~ /\S/ ? 0 : 1;
}

# --- the resident set ---------------------------------------------------------

my $processor = "$root/lazysite-processor.pl";
my @parts = sort glob("$root/lazysite-processor/*.pm");
ok( scalar @parts, 'the processor has parts' );

my $proc_text = slurp($processor);
my %text      = ( 'lazysite-processor.pl' => $proc_text );
$text{"lazysite-processor/" . ( $_ =~ m{([^/]+)\z} )[0]} = slurp($_) for @parts;

my $door = $text{'lazysite-processor/front-door.pm'};
my ($preload_list) = $door =~ /our \@POOL_PRELOAD\s*=\s*qw\(([^)]*)\)/;
ok( defined $preload_list, 'the pool preload list is found (front-door.pm @POOL_PRELOAD)' );
my @preload = split ' ', ( $preload_list // '' );

# What the processor and its parts load: _lazy_lib('X') and require X.
my ( %named, %always );
for my $f ( sort keys %text ) {
    my $code = join "\n", map { $_->[1] } code_lines( $text{$f} );
    my $raw  = $text{$f};
    $raw =~ s/^\s*#.*$//mg;
    $named{$_} = $f for $raw =~ /\b_lazy_lib\(\s*'(Lazysite::[\w:]+)'/g;
    $named{$_} = $f for $raw =~ /\brequire\s+(Lazysite::[\w:]+)/g;
}
# loaded by the script's own BEGIN, in every runtime
$always{'Lazysite::Timing'} = 1;

subtest 'the preload list is exactly the modules the processor loads on first use' => sub {
    my %in = map { $_ => 1 } @preload;
    for my $m ( sort keys %named ) {
        next if $always{$m};
        ok( $in{$m}, "$m is named in " . $named{$m} . ' and is preloaded' )
            or diag("add $m to \@POOL_PRELOAD in lazysite-processor/front-door.pm, so the pool's parent loads it once");
    }
    my %seen = map { $_ => 1 } keys %named;
    for my $m (@preload) {
        ok( $seen{$m}, "$m is preloaded and something loads it" )
            or diag("$m is in \@POOL_PRELOAD but no part names it; drop it");
    }
};

sub module_file { my ($m) = @_; return "$root/lib/" . join( '/', split /::/, $m ) . '.pm' }

# The closure: each preloaded module, everything it use/requires, and so on.
my %module;
my @queue = ( @preload, keys %always );
while ( my $m = shift @queue ) {
    next if $module{$m};
    my $f = module_file($m);
    next unless -f $f;
    $module{$m} = slurp($f);
    my $raw = $module{$m};
    $raw =~ s/^\s*#.*$//mg;
    $raw =~ s/^=\w+.*?^=cut\s*$//msg;
    $raw =~ s/^__END__.*//ms;
    push @queue, $raw =~ /\b(?:use|require)\s+(Lazysite::[\w:]+)/g;
}
$text{"lib/" . join( '/', split /::/, $_ ) . '.pm'} = $module{$_} for keys %module;
cmp_ok( scalar( keys %module ), '>', scalar(@preload), 'the resident set reaches past the preload list (the use/require closure)' );

# --- classify every file-scope variable ---------------------------------------

# The corpus the mutation search reads: all resident code, declarations kept.
my $corpus = join "\n", map { join "\n", map { $_->[1] } code_lines( $text{$_} ) } sort keys %text;

# Is $var (with sigil) assigned to, changed or aliased anywhere in the resident
# code, other than at its declaration?
sub mutated {
    my ( $var, $declaring_file, $decl_line ) = @_;
    my ( $sig, $n ) = $var =~ /\A([\$\@%])(\w+)\z/;
    my $pk = qr/(?:[\w:]*::)?/;
    my $op = qr/(?:\|\||&&|\/\/|\*\*|<<|>>|[-+*\/.x|&^%])?=(?![=~])/;
    my @pat;
    if ( $sig eq '$' ) {
        push @pat, qr/\$$pk$n\b(?!\s*[\[{])\s*$op/,
            qr/\(\s*(?:[^;()]*,\s*)?[\$\@%]\s*(?:,[^;()]*)?\)\s*=(?![=~])/,
            qr/(?:\+\+|--)\s*\$$pk$n\b/, qr/\$$pk$n\b\s*(?:\+\+|--)/,
            qr/\b(?:undef|chomp|chop|local)\s*\(?\s*\$$pk$n\b(?!\s*[\[{])/,
            qr/\$$pk$n\b\s*=~\s*(?:s|tr|y)\b/, qr/\\\s*\$$pk$n\b(?!\s*[\[{])/,
            qr/\$\{\s*\\?\$$pk$n\s*\}\s*$op/;
        # a scalar holding a reference is changed through it
        push @pat, qr/\$$pk$n\s*->\s*[\[{][^;]*?[\]}]\s*$op/, qr/\@\{\s*\$$pk$n\s*\}\s*=/, qr/\bpush\s*\(?\s*\@\{\s*\$$pk$n\b/;
    }
    elsif ( $sig eq '%' ) {
        push @pat, qr/\$$pk$n\s*\{[^;]*?\}\s*$op/, qr/\@$pk$n\s*\{[^;]*?\}\s*=(?![=~])/,
            qr/%$pk$n\b\s*=(?![=~])/, qr/\(\s*%$pk$n\s*\)\s*=/, qr/\bdelete\s*\(?\s*[\$\@]$pk$n\s*\{/,
            qr/\bundef\s*\(?\s*%$pk$n\b/, qr/\\\s*%$pk$n\b/, qr/\blocal\s+[\$\@%]$pk$n\b/,
            qr/\$$pk$n\s*\{[^;]*?\}\s*(?:\+\+|--)/, qr/(?:\+\+|--)\s*\$$pk$n\s*\{/,
            qr/\bpush\s*\(?\s*\@\{\s*\$$pk$n\s*\{/, qr/\beach\s+%$pk$n\b/;
    }
    else {
        push @pat, qr/\@$pk$n\b\s*=(?![=~])/, qr/\(\s*\@$pk$n\s*\)\s*=/, qr/\b(?:push|unshift|splice|pop|shift)\s*\(?\s*\@$pk$n\b/,
            qr/\$$pk$n\s*\[[^;]*?\]\s*$op/, qr/\bundef\s*\(?\s*\@$pk$n\b/, qr/\\\s*\@$pk$n\b/,
            qr/\blocal\s+[\$\@%]$pk$n\b/, qr/\bfor(?:each)?\s*(?:my\s+\$\w+\s*)?\(\s*\@$pk$n\s*\)/;
    }
    # Blank the declaration statements of this name so `my $x = 1;` is not a mutation.
    my $c = $corpus;
    $c =~ s/\b(?:my|our)\s*\([^)]*\)[^;]*;/ /g;
    $c =~ s/\b(?:my|our)\s+[\$\@%]\w+\s*(?:=[^;]*)?;/ /g;
    for my $p (@pat) { return 1 if $c =~ $p }
    return 0;
}

my @all;
for my $f ( sort keys %text ) {
    my $is_part = $f =~ m{\Alazysite-processor/};
    my %done;
    for my $d ( file_scope_decls( $text{$f} ) ) {
        # A part's bare `our ( ... );` aliases the script's variables (t/lint/215):
        # the script declares them, and they are classified there.
        next if $is_part && $d->{kind} eq 'our' && $d->{list} && $d->{rest} !~ /=/;
        # Exporter plumbing is not state
        next if $d->{var} =~ /\A[\$\@%](?:EXPORT_OK|EXPORT|EXPORT_TAGS|ISA|VERSION)\z/;
        next if $done{ $d->{var} }++;
        $d->{file} = $f;
        push @all, $d;
    }
}
cmp_ok( scalar @all, '>', 50, 'the scan finds the resident code\'s file-scope variables' );


# --- the classification ----------------------------------------------------------
#
# What is left after CONSTANT (found above) is classified here, and every entry
# says why. Three kinds:
#
#   [ reset => 'sub' ]   a sub that clears it at the request boundary; the test
#                        reads that sub and fails if the variable is not in it;
#   [ unset => '' ]      nothing the pooled request path does assigns it (the
#                        surfaces that set it run as their own process); the test
#                        fails if the processor or its parts assign it from outside;
#   [ exempt => 'why' ]  it holds something that is not about a request.
my $SITE = 'the site this pool serves: one pool per site, so it is the same for every request, set once';
my $KEYED = 'a cache keyed on what it caches (the file\'s path, mtime and size), so a changed file misses';
my $STATUS = 'the outcome of the most recent read, set by that read before anything consults it';
my $BEGIN_CONST = 'a constant set in BEGIN (assigned there because the main flow runs before a plain assignment would)';

# Variables of the same name mean the same thing wherever they are declared.
my %GENERIC = (
    '$DOCROOT'      => [ exempt => $SITE ],
    '$LAZYSITE_DIR' => [ exempt => $SITE ],
    '$AUTH_DIR'     => [ exempt => $SITE ],
);

# Whole files whose package variables are the manager, scheduler and mail
# surfaces' own request state. The pooled processor loads them only to ask a
# reach question (Odoo.pm's domain_refusal) or to queue a send, never as the
# entry point; the surfaces that set $action, $auth_user and the rest are their
# own processes. Held by the `unset` check below: nothing in the processor or its
# parts assigns a package variable of any of them.
my $OTHER_SURFACE = 'the manager / scheduler / mail surfaces\' own state, set by those surfaces\' processes; the pooled processor never assigns it (checked below)';
my @OTHER_SURFACE = qr{\Alib/Lazysite/(?:Manager/|Daemon/|Outbox\.pm|Notify\.pm|Git\.pm|Plugins/|Lifecycle\.pm|Mail\.pm|Unsubscribe\.pm)};

my %T = (
    'lazysite-processor.pl' => {
        '$TIMING'                => [ exempt => 'whether the timing helper loaded: a property of the install, decided once in BEGIN' ],
        '$FORM_TS_PLACEHOLDER'   => [ exempt => $BEGIN_CONST ],
        '$FORM_TK_PLACEHOLDER'   => [ exempt => $BEGIN_CONST ],
        '$FRONT_DOOR'            => [ exempt => 'the pool\'s front-door setting, read once from its environment at start (t/lint/43: a request replaces %ENV)' ],
        '$FRONT_CGIBIN'          => [ exempt => 'the pool\'s surfaces directory, read once from its environment at start' ],
        '$RELAY_TIMEOUT'         => [ exempt => 'the pool\'s relay timeout, read once from its environment at start' ],
        '$CONF_OVERRIDE'         => [ exempt => 'the --conf command-line argument, absent in a pool' ],
        '$CONF_FILE'             => [ exempt => 'the path of this site\'s lazysite.conf, derived from the docroot once' ],
        '$LAYOUT_DIR'            => [ exempt => 'a path derived from the docroot once' ],
        '$REGISTRY_DIR'          => [ exempt => 'a path derived from the docroot once' ],
        '$MANAGER_LAYOUT'        => [ exempt => 'a path derived from the docroot once' ],
        '$CACHE_BASE'            => [ exempt => 'a path derived from the docroot once' ],
        '$LAYOUT_CACHE_DIR'      => [ exempt => 'a path derived from the docroot once' ],
        '$CT_CACHE_DIR'          => [ exempt => 'a path derived from the docroot once' ],
        '$TT_COMPILE_DIR'        => [ exempt => 'a path derived from the docroot once' ],
        '$HOST_CACHE_DIR'        => [ exempt => 'a path derived from the docroot once' ],
        '$REGISTRY_CACHE_DIR'    => [ exempt => 'a path derived from the docroot once' ],
        '@TT_DEPS'               => [ reset  => 'process_md' ],
        '$TT_DEP_LIVE'           => [ reset  => 'process_md' ],
        '%AUTH_CONTEXT'          => [ reset  => 'handle_one_request' ],
        '%ACCESS_REC'            => [ reset  => 'handle_one_request' ],
        '$RESPONSE_LANG'         => [ reset  => 'reset_request_state' ],
        '$REQUEST_CROOT'         => [ reset  => 'reset_request_state' ],
        '$DRAFT_BYTES'           => [ reset  => 'reset_request_state' ],
        '$DRAFT_MD'              => [ reset  => 'reset_request_state' ],
        '$ACL_MAP_CACHE'         => [ reset  => 'reset_request_state' ],
        # SM1181 S2: the request's identity value; handle_one_request clears it at
        # its end as well (t/integration/292 holds both ends).
        '$REQUEST_IDENT'         => [ reset  => 'reset_request_state' ],
        '%PAYMENT_CONTEXT'       => [ reset  => 'reset_request_state' ],
        # SM1118: this request's maintenance outcome (the gate, the 503 page, the banner).
        '%MAINT'                 => [ reset  => 'reset_request_state' ],
        '%PREVIEW_CONTEXT'       => [ reset  => 'main' ],
        '$FALLBACK_LAYOUT'       => [ exempt => 'constant text (a heredoc)' ],
        '%ALIAS_OVERRIDE_KEYS'   => [ exempt => 'a constant set of conf keys' ],
        '$RUNTIME'               => [ exempt => '\'pool\' or \'cgi\', decided once at start' ],
        '%_droots_cache'         => [ exempt => 'a function of lazysite.conf, keyed on its mtime' ],
        '$_droots_sig'           => [ exempt => 'the key of the cache above' ],
        '$_droots_loaded'        => [ exempt => 'whether the cache above holds anything' ],
        '%_site_vars_cache'      => [ reset  => 'reset_request_state' ],
        '$_site_vars_loaded'     => [ reset  => 'reset_request_state' ],
        '$_site_vars_sig'        => [ reset  => 'reset_request_state' ],
    },
    'lazysite-processor/access-log.pm' => { '$_UNITS' => [ reset => '_reset_units' ] },
    'lazysite-processor/acl.pm' => {
        '%_dn_cache'           => [ exempt => $KEYED ],
        '$_idx_map'            => [ exempt => 'the ACL map it indexes, held with the index so one cannot be reused for another (SM1069); the map is reset per request' ],
        '$_idx'                => [ exempt => 'the index of the map above' ],
        '%_acl_store'          => [ exempt => 'the parsed ACL store keyed on path, mtime, size and ctime (SM973 keyed it; $ACL_MAP_CACHE is the per-request copy)' ],
        '$PRIVATE_ROOT_CACHE'  => [ exempt => 'a path derived from the docroot once' ],
    },
    'lazysite-processor/auth.pm'      => { '%_peek_cache' => [ reset => '_reset_peek_cache' ] },
    'lazysite-processor/forms.pm'     => { '@FORM_FIELD_KINDS' => [ exempt => 'a table of code references, constant' ] },
    'lazysite-processor/front-door.pm' => { '@POOL_PRELOAD' => [ exempt => 'the list of modules the pool loads before it forks' ] },
    'lazysite-processor/include.pm' => {
        '%URL_SAFE_SCHEME' => [ exempt => $BEGIN_CONST ],
        '%URL_SAFE_NAMED'  => [ exempt => $BEGIN_CONST ],
    },
    'lazysite-processor/layout.pm' => {
        '$LAZYSITE_VERSION' => [ exempt => 'the installed release, read once from the install state' ],
        '$ENGINE_MTIME'     => [ exempt => 'when the engine was installed, read once from the install state' ],
    },
    'lazysite-processor/pipeline.pm' => {
        '%STATIC_DENY'           => [ exempt => $BEGIN_CONST ],
        '@SOURCE_ALTERNATE_KEYS' => [ exempt => $BEGIN_CONST ],
        '%RENDER_QUERY'          => [ exempt => 'localised (`local %RENDER_QUERY`) by process_md for the render and restored on exit' ],
        '$RENDER_BY_ADDRESS'     => [ reset  => 'main' ],
    },
    'lazysite-processor/registries.pm' => {
        '$_has_registries'     => [ exempt => 'whether the site has registry templates: availability, not access (SM973 checked it)' ],
        '$REGISTRY_REBUILDING' => [ exempt => 'localised (`local $REGISTRY_REBUILDING`) in the detached rebuild' ],
    },
    'lazysite-processor/sources.pm' => {
        '$_scan_id_done' => [ reset => '_reset_scan_identity' ],
        '$_scan_user'    => [ reset => '_reset_scan_identity' ],
        '@_scan_groups'  => [ reset => '_reset_scan_identity' ],
    },
    'lib/Lazysite/Audit.pm' => {
        '$write_warned' => [ exempt => 'warn-once latch for a failing audit write, per process on purpose' ],
        '%_TRAIL_MEMO'  => [ exempt => $KEYED ],
    },
    'lib/Lazysite/Auth/Acl.pm' => {
        '$auth_user'  => [ unset  => '' ],
        '$token_auth' => [ unset  => '' ],
        '@user_groups' => [ unset => '' ],
        '%token_caps' => [ unset  => '' ],
        '$ACLS_FAULT' => [ exempt => $STATUS ],
        '%_acls_cache' => [ exempt => $KEYED ],
    },
    'lib/Lazysite/Auth/AddressLists.pm' => {
        '$FAULT'       => [ exempt => $STATUS ],
        '$cache_key'   => [ exempt => $KEYED ],
        '$cache_lists' => [ exempt => $KEYED ],
        '$cache_sets'  => [ exempt => $KEYED ],
        '%WARNED'      => [ exempt => 'warn-once latch for a bad list entry; holds the entry\'s text, not a visitor' ],
    },
    'lib/Lazysite/Auth/AddressScope.pm' => {
        '%ADDR_MEMO'          => [ exempt => 'the client address worked out once per (auth dir, REMOTE_ADDR, X-Forwarded-For): the request\'s own inputs are the key, so one visitor\'s address never answers for another\'s' ],
        '%CONF_MEMO'          => [ exempt => $KEYED ],
        '%SEEN_THIS_PROCESS'  => [ exempt => 'dedupes the hourly address-refusal audit row on (target, address, hour); it suppresses a duplicate row and decides nothing about a request, and the worker\'s recycle bounds it' ],
    },
    'lib/Lazysite/Auth/Identity.pm' => { '%conf_cache' => [ exempt => $KEYED ] },
    'lib/Lazysite/Auth/Session.pm' => {
        '%LIFETIME_CACHE' => [ exempt => 'the session lifetime setting, keyed on the site directory' ],
        # SM1181 S2: cleared per request by the processor too, not only by the
        # verifier's own stages.
        '$STORE_FAULT'    => [ reset  => 'reset_request_state' ],
    },
    'lib/Lazysite/Auth/Settings.pm' => {
        '@CAP_KEYS'                    => [ exempt => 'the list of capability names, constant' ],
        '$USERS_UNREADABLE'            => [ exempt => $STATUS ],
        '$GROUPS_UNREADABLE'           => [ exempt => $STATUS ],
        '$GROUP_SETTINGS_UNREADABLE'   => [ exempt => $STATUS ],
        '$GROUP_SETTINGS_UNDECODABLE'  => [ exempt => $STATUS ],
        '$_GS_DECODE_WARNED'           => [ exempt => 'warn-once latch' ],
        '$ADDRESS_RULES'               => [ exempt => 'a switch the users tool turns off; localised (`local`) where it is, on in every web script' ],
        '%_settings_cache'             => [ exempt => $KEYED ],
        '$_readable'                   => [ exempt => $STATUS ],
    },
    'lib/Lazysite/Data/Owned.pm'  => { '%RESERVED' => [ exempt => 'derived from constants' ], '%STAMPED' => [ exempt => 'derived from constants' ] },
    'lib/Lazysite/Data/Tables.pm' => { '%_descriptor_cache' => [ exempt => $KEYED ] },
    'lib/Lazysite/I18n.pm'        => { '%CACHE' => [ exempt => 'the per-language chrome strings, keyed on (docroot, language); site content, not a visitor\'s' ] },
    'lib/Lazysite/Odoo.pm' => {
        '%CALL_FIELD' => [ exempt => 'derived from a constant list' ],
        '$TRANSPORT'  => [ exempt => 'a test seam; unset in the product' ],
        '$LAST_VIA'   => [ exempt => $STATUS ],
        '%REGISTRY'    => [ exempt => 'OOM\'s operation classes for one site configuration, keyed on the docroot, namespaces, pack directories, cache directory and OOM version (SM1179); it holds no person' ],
    },
    'lib/Lazysite/Odoo/Daemon.pm' => { '%NAME' => [ exempt => 'the daemon\'s name, a function of the docroot and keyed on it' ] },
    'lib/Lazysite/Odoo/Session.pm' => { '$HTTP' => [ exempt => 'a test seam; unset in the product' ] },
    'lib/Lazysite/Timing.pm' => {
        '%KNOWN'    => [ exempt => 'derived from a constant list' ],
        '$LOADED'   => [ exempt => 'when the file loaded; worker_started() moves it at a fork' ],
        '$BEGUN'    => [ exempt => 'whether a first request has begun, per process on purpose (the `load` phase)' ],
        '%CONF'     => [ exempt => $KEYED ],
        '%PH'       => [ reset  => 'begin' ],
        '%DESC'     => [ reset  => 'begin' ],
        '$CURRENT'  => [ reset  => 'begin' ],
        '$LAST'     => [ reset  => 'begin' ],
        '$OPERATOR' => [ reset  => 'begin' ],
        '$LZDIR'    => [ reset  => 'begin' ],
    },
);

# The body of the named sub, from whichever resident file defines it.
sub sub_body {
    my ($name) = @_;
    for my $f ( sort keys %text ) {
        my @l = code_lines( $text{$f} );
        for ( my $i = 0 ; $i < @l ; $i++ ) {
            next unless $l[$i][1] =~ /\bsub\s+\Q$name\E\b/;
            my ( $depth, $body, $started ) = ( 0, '', 0 );
            for ( my $j = $i ; $j < @l ; $j++ ) {
                my $line = $l[$j][1];
                $body .= "$line\n";
                for my $ch ( split //, $line ) {
                    if    ( $ch eq '{' ) { $depth++; $started = 1 }
                    elsif ( $ch eq '}' ) { $depth-- }
                }
                return $body if $started && $depth <= 0;
            }
        }
    }
    return undef;
}

# `unset`: does anything in the processor or its parts assign this package
# variable of another module, other than by `local` (which restores it)?
my $entry_code = join "\n", map { join "\n", map { $_->[1] } code_lines( $text{$_} ) }
    grep { !m{\Alib/} } sort keys %text;
sub assigned_from_entry {
    my ($var) = @_;
    my ( $sig, $n ) = $var =~ /\A([\$\@%])(\w+)\z/;
    return $entry_code =~ /(?<!local )(?<!local\()[\$\@%]Lazysite::[\w:]*::\Q$n\E\b\s*(?:\|\||\/\/)?=(?![=~])/ ? 1 : 0;
}

my ( %seen_entry, @unclassified );
for my $d (@all) {
    my ( $f, $v ) = ( $d->{file}, $d->{var} );
    next if literal_init( $d->{rest} ) && !mutated( $v, $f, $d->{line} );

    my $c = $T{$f} && $T{$f}{$v};
    $seen_entry{$f}{$v} = 1 if $c;
    $c ||= $GENERIC{$v};
    if ( !$c && grep { $f =~ $_ } @OTHER_SURFACE ) {
        $c = [ unset => '' ];
    }
    if ( !$c ) {
        push @unclassified, $d;
        next;
    }
    my ( $kind, $arg ) = @$c;
    if ( $ENV{LINT_269_DUMP} ) { printf "%s:%d %s %s\n", $f, $d->{line}, $v, $kind }
    if ( $kind eq 'reset' ) {
        my $body = sub_body($arg);
        ok( defined $body && $body =~ /[\$\@%](?:\w+::)*\Q@{[ substr $v, 1 ]}\E\b/,
            "$f: $v is cleared by $arg" )
            or diag("$f:$d->{line} $v is declared as reset by $arg, which does not mention it");
    }
    elsif ( $kind eq 'unset' ) {
        ok( !assigned_from_entry($v), "$f: $v is not assigned by the pooled request path" )
            or diag("$f:$d->{line} $v: the processor or a part assigns it; it is request state now and must be reset");
    }
    else {
        ok( length $arg, "$f: $v is exempt, with a reason" );
    }
}

ok( !@unclassified, 'every file-scope variable in the resident code is constant, reset, unset or exempt with a reason' )
    or diag(
    ( join '', map { "  $_->{file}:$_->{line}  $_->{kind} $_->{var}   - a file-scope variable a pooled worker keeps for its life.\n" } @unclassified )
        . "Reset it at the request boundary (reset_request_state / handle_one_request) and list it as `reset`, or list it as `exempt` with the reason it holds nothing about a request.\n" );

for my $f ( sort keys %T ) {
    for my $v ( sort keys %{ $T{$f} } ) {
        ok( $seen_entry{$f}{$v}, "$f: the table's $v is declared there and is not a constant" )
            or diag("stale entry: $f has no non-constant file-scope $v; remove it from the table");
    }
}

done_testing();
