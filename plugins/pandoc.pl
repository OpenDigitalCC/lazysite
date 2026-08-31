#!/usr/bin/perl
# SM694: turn a page into a branded PDF, through a pandoc the operator installed.
#
# THE DEPENDENCY IS DECLARED, NOT DISCOVERED. `bins` (SM694 groundwork, 0.11.7)
# lets a plugin name a PROGRAM the way `deps` names a Perl module, so SM472's
# rule applies unchanged: a plugin that cannot run is not enabled. An operator
# without pandoc is refused at the switch, told it is a program rather than a
# CPAN package, and never gets a button that fails at first use.
#
# THE EXECUTION BOUNDARY, which the filing said to settle before writing this:
#
#   1. A BOUNDED ROOT, as far as the wrapper allows. md-to-pdf owns the pandoc
#      invocation, so this plugin cannot pass --sandbox or --resource-path
#      through it. What it CAN control is the brands base and the working
#      directory. MD_TO_PDF_BRANDS is pinned to the site's own brand folder, so
#      a document naming a brand cannot pull a template from elsewhere.
#
#      MEASURED, because the working directory looked like a confinement and is
#      not one: the wrapper resolves a document's relative references against
#      the SOURCE FILE's directory, not against the cwd. Converting the same
#      page from two different working directories embedded the same image both
#      times. So the scratch directory below buys predictable output, not
#      containment, and this comment does not claim otherwise.
#
#      THE RESIDUAL RISK, stated rather than hidden: an absolute path - or
#      enough leading ../ - in a document's image reference is resolved by
#      pandoc inside the wrapper, where this plugin has no say. Converting is
#      gated on manage_content, so the author already reads the content tree,
#      but not arbitrary host files, and that gap is real until the wrapper
#      offers a sandbox flag or a passthrough of its own. Recorded on SM694.
#
#   2. A FIXED ARGUMENT LIST. Every argument is built here. Nothing a caller
#      sends reaches the command line, and the list is a Perl list passed to a
#      list-form exec - no shell, so no quoting question to get wrong. The BRAND
#      is chosen in the document's own front matter (`brand: <name>`), which is
#      the wrapper's interface; the plugin's job is to bound where brands are
#      read FROM, not to pass one on a command line.
#
#   3. READ AUTHORITY. Converting a page is producing a copy of it, so the
#      caller must be able to READ it. The conversion asks the same ACL the
#      content path answers to; otherwise this is an ACL bypass with a nice
#      output format.
#
#   4. SYNCHRONOUS, AND BOUNDED. There is no queue and no daemon (SM666), so
#      the conversion happens in the request with a timeout and a size cap. A
#      job system is what SM579 is about; inventing half of one here is how a
#      site engine becomes a multipurpose tool.
use strict;
use warnings;
use JSON::PP qw(encode_json);

BEGIN {
    require Cwd;
    require File::Basename;
}

# How long a conversion may take, and how big its input may be. Both are
# deliberately small: a manager request is not the place for a long job, and a
# refusal that says "too large" is better than a CGI killed halfway.
my $TIMEOUT_SECONDS = 20;
my $MAX_INPUT_BYTES = 512 * 1024;

sub describe {
    return {
        id          => 'pandoc',
        name        => 'Branded PDF creation',
        version     => '1',
        description => 'Convert a page to a branded PDF through md-to-pdf, the '
            . 'pandoc wrapper installed on this server. Brand assets live in '
            . 'the site files, so an operator maintains them where they '
            . 'maintain content.',
        owns => {

            # No new capability. Converting a page is reading it in another
            # format, so it rides on manage_content rather than inventing an
            # authority an operator would have to reason about separately.
            capabilities => [],

            # SM694: the executable form. What this plugin CALLS is md-to-pdf,
            # the pandoc wrapper - which owns the pandoc and XeLaTeX invocation,
            # the templates and the brand machinery. Declaring `pandoc` here
            # would let the plugin enable on a host that has pandoc and not the
            # wrapper, which is the state `bins` exists to prevent.
            bins => ['md-to-pdf'],

            # The brand folder is this plugin's storage, under lazysite/ where
            # nothing is served.
            storage => ['lazysite/brands/'],
        },
        config_file   => 'lazysite/pandoc.conf',
        config_schema => [
            { key => 'brand_dir',
                label   => 'Where brand assets live',
                type    => 'text',
                default => 'lazysite/brands',
                note    => 'A folder holding one subfolder per brand, each with '
                    . 'its template and any logo or font it uses. Manage it on '
                    . 'the Files page like any other folder. It sits under '
                    . 'lazysite/ so it is NOT served: a brand folder in the '
                    . 'document root answers an anonymous request, which '
                    . 'publishes your letterhead to anyone who guesses the path.',
            },
        ],
        actions => [
            { id => 'status',
                label => 'Status',
                run   => 'action',
                note  => 'Checks that the md-to-pdf converter is installed and '
                    . 'answers, reports its version, and lists the brands found.',
            },
        ],
    };
}

# The converter the plugin will actually run. Resolved from PATH the same way
# the enable-time check does, so "enabled" and "works" cannot disagree.
sub _converter_path {
    my $path = $ENV{PATH} // '/usr/local/bin:/usr/bin:/bin';
    for my $dir ( split /:/, $path ) {
        next unless length $dir;
        return "$dir/md-to-pdf" if -x "$dir/md-to-pdf" && !-d _;
    }
    return undef;
}

sub _converter_version {
    my ($bin) = @_;
    return undef unless defined $bin;
    my $out = '';
    if ( open my $fh, '-|', $bin, '--version' ) {
        local $/;
        $out = <$fh> // '';
        close $fh;
    }
    return ( $out =~ /([0-9]+\.[0-9][\w.]*)/ ) ? $1 : undef;
}

# Does this wrapper understand --no-viewer? It must: on a server there is no
# viewer to open, and a converter that tries to open one blocks the request.
# Asked rather than assumed, because an unknown flag fails the whole run.
sub _supports_no_viewer {
    my ($bin) = @_;
    return 0 unless defined $bin;
    my $out = '';
    if ( open my $fh, '-|', $bin, '--help' ) {
        local $/;
        $out = <$fh> // '';
        close $fh;
    }
    return $out =~ /--no-viewer/ ? 1 : 0;
}

# The brands present: one subfolder per brand under the configured directory.
# A NAME, validated as one path segment - a brand never carries a path, because
# the value is joined to a directory and a caller must not choose the location.
sub _brands {
    my ( $docroot, $dir ) = @_;
    $dir = 'lazysite/brands' unless defined $dir && length $dir;
    return [] if $dir =~ m{(?:\A|/)\.\.(?:/|\z)};
    my $root = "$docroot/$dir";
    return [] unless -d $root;
    opendir my $dh, $root or return [];
    my @out = sort grep { /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/ && -d "$root/$_" }
        readdir $dh;
    closedir $dh;
    return \@out;
}

# THE CONVERSION.
#
# Every argument is built here. A caller supplies a content path and a brand
# NAME; neither reaches the command line unchecked, and the list form of open
# means no shell parses any of it - there is no quoting to get wrong because
# there is no quoting.
sub convert {
    my (%o)     = @_;
    my $docroot = $o{docroot} // '';
    my $rel     = $o{path}    // '';
    my $brand   = $o{brand};
    my $dir     = $o{brand_dir} // 'lazysite/brands';

    my $bin = _converter_path();
    return { ok => 0, error => 'md-to-pdf is not installed on this server' }
        unless $bin;

    # ONE SEGMENT AT A TIME, no traversal, no absolute path. The content path
    # decides which file is read, so it is checked before anything opens it.
    return { ok => 0, error => 'a content path is required' }
        unless length $rel;
    $rel =~ s{\A/+}{};
    return { ok => 0, error => 'invalid content path' }
        if $rel =~ m{(?:\A|/)\.\.(?:/|\z)} || $rel =~ /\0/;
    return { ok => 0, error => 'only Markdown pages can be converted' }
        unless $rel =~ /\.md\z/;

    my $src = "$docroot/$rel";
    return { ok => 0, error => 'no such page' } unless -f $src;

    my $size = -s $src;
    return { ok => 0,
        error => "the page is larger than this converter accepts "
            . "($MAX_INPUT_BYTES bytes)" }
        if defined $size && $size > $MAX_INPUT_BYTES;

    # THE BRAND IS CHOSEN IN THE DOCUMENT, not on the command line - that is
    # md-to-pdf's interface (`brand: <name>` in the front matter). So the
    # plugin's job is not to pass a brand but to bound where brands are read
    # FROM: MD_TO_PDF_BRANDS pins the base to the site's own folder, so a
    # document naming a brand cannot pull a template from elsewhere on the host.
    my $brands_base = "$docroot/$dir";
    if ( defined $brand && length $brand ) {
        my $known = _brands( $docroot, $dir );
        return { ok => 0,
            error => "unknown brand '$brand'. Present: "
                . ( @{$known} ? join( ', ', @{$known} ) : '(none)' ) }
            unless grep { $_ eq $brand } @{$known};
    }

    # Convert in a scratch directory. The wrapper names its output from the
    # document's title and writes it to the CWD, so a scratch dir is both how
    # the output is found and how the docroot is kept clean of stray PDFs.
    my $work = "$docroot/lazysite/cache/pandoc-$$-" . time;
    require File::Path;
    File::Path::make_path($work);
    return { ok => 0, error => 'could not prepare a working directory' }
        unless -d $work;

    my @cmd = ( $bin, '--no-viewer', $src );

    my $pid = fork();
    unless ( defined $pid ) {
        File::Path::remove_tree($work);
        return { ok => 0, error => 'could not start the converter' };
    }
    if ( !$pid ) {
        chdir $work or exit 127;

        # Bound the brands base to this site. Anything the document names is
        # resolved under here or not at all.
        $ENV{MD_TO_PDF_BRANDS} = $brands_base if -d $brands_base;

        # Checked, because a child that cannot redirect would otherwise write
        # the converter's chatter onto the CGI's own STDOUT - into the HTTP
        # response, mid-header. Exit instead; the parent reports the failure.
        open STDOUT, '>',  "$work/.out" or exit 127;
        open STDERR, '>&', \*STDOUT     or exit 127;
        exec { $cmd[0] } @cmd;
        exit 127;
    }

    # BOUNDED. There is no queue and no daemon (SM666), so this runs in the
    # request and must be unable to run away with it.
    local $SIG{ALRM} = sub { kill 'TERM', $pid };
    alarm $TIMEOUT_SECONDS;
    waitpid $pid, 0;
    my $status = $?;
    alarm 0;

    # The wrapper names the PDF from the document title, so the plugin finds it
    # rather than predicting it - predicting a filename from a title means
    # reimplementing somebody else's slug rules and being wrong the first time
    # a title has a colon in it.
    my ($pdf) = glob("$work/*.pdf");
    unless ( $pdf && -s $pdf && $status == 0 ) {
        my $why = '';
        if ( open my $l, '<', "$work/.out" ) { local $/; $why = <$l> // ''; close $l }
        File::Path::remove_tree($work);
        $why =~ s/\s+/ /g;
        return { ok => 0,
            error => 'the conversion did not produce a document'
                . ( length $why ? ": " . substr( $why, -200 ) : '' ) };
    }
    return { ok => 1, pdf => $pdf, bytes => ( -s $pdf ) };
}

sub plugin_status {
    my ($docroot) = @_;
    my $bin       = _converter_path();
    my $ver       = _converter_version($bin);
    my $brands    = _brands( $docroot, 'lazysite/brands' );

    # A SENTENCE, not a bare ok. The manager renders an action's result, and a
    # status that answered only `ok:1` showed as "Done" - which says the button
    # worked, not what it found.
    my $msg = !$bin
        ? 'md-to-pdf is not installed on this server, so this plugin cannot convert anything.'
        : sprintf(
        'md-to-pdf %s is installed and answering at %s. %s',
        ( defined $ver ? $ver : '(version unknown)' ), $bin,
        ( @{$brands}
            ? 'Brands found: ' . join( ', ', @{$brands} ) . '.'
            : 'No brands yet - add a folder under lazysite/brands/ on the Files page.' )
        );

    return {
        ok        => 1,
        message   => $msg,
        available => $bin ? JSON::PP::true : JSON::PP::false,
        converter => $bin,
        version   => $ver,
        no_viewer => _supports_no_viewer($bin) ? JSON::PP::true : JSON::PP::false,
        brands    => $brands,
    };
}

sub run {
    my (@argv) = @_;
    my %opt;
    for my $i ( 0 .. $#argv ) {
        $opt{describe} = 1               if $argv[$i] eq '--describe';
        $opt{docroot}  = $argv[ $i + 1 ] if $argv[$i] eq '--docroot';
        $opt{action}   = $argv[ $i + 1 ] if $argv[$i] eq '--action';
    }
    if ( $opt{describe} ) {
        print encode_json( describe() );
        return 0;
    }
    my $docroot = $opt{docroot} // $ENV{DOCUMENT_ROOT} // '';
    my $act     = $opt{action}  // '';
    if ( $act eq 'status' ) {
        print encode_json( plugin_status($docroot) );
        return 0;
    }
    print encode_json( { ok => 0, error => "unknown action '$act'" } );
    return 1;
}

run(@ARGV) unless caller;

1;
