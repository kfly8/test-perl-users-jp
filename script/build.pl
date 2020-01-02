use strict;
use warnings;
use utf8;
use feature qw/state/;

use FindBin;
use File::Basename qw(basename);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec::Functions qw(catdir catfile);
use Date::Format qw(time2str);

use Text::Xatena;
use Text::Xatena::Inline;
use Text::Markdown;
use Text::MicroTemplate;

my $REPO_DIR         = catdir($FindBin::Bin, '..');
my $CONTENT_ROOT_DIR = catdir($REPO_DIR, 'content');
my $DEST_ROOT_DIR    = catdir($REPO_DIR, 'docs');
my $LAYOUTS_ROOT_DIR = catdir($REPO_DIR, 'layouts');

main();

sub main {
    find({
        no_chdir => 1,
        wanted   => \&wanted,
    }, $CONTENT_ROOT_DIR);
}

sub wanted {
    return unless -f $File::Find::name;

    my $file = $File::Find::name;
    my $dir  = $File::Find::dir;

    my $subdir   = $dir =~ s!$CONTENT_ROOT_DIR!!r;
    my $dest_dir = catdir($DEST_ROOT_DIR, $subdir);

    if (!-d $dest_dir) {
        make_path($dest_dir);
    }

    if (is_text($file)) {
        my $html = convert_html($file);

        my $basename  = basename($file);
        my $dest_name = $basename =~ s!\.[^.]+$!.html!r;
        my $dest_html = catfile($dest_dir, $dest_name);

        write_file($dest_html, $html);
    }
    else { # css, js, png ...
        copy($file, $dest_dir) or die $!;
    }
}


sub convert_html {
    my ($file) = @_;

    my $entry    = parse_entry($file);
    my $layout   = layout_file($entry->{layout});
    my $template = read_file($layout);

    return render_string($template, {
        title       => $entry->{title},
        description => $entry->{description},
        text        => $entry->{text},
        update_at   => $entry->{update_at},
        pubdate     => $entry->{pubdate},
        author      => $entry->{author},
        tags        => $entry->{tags},
    });
}

sub parse_entry {
    my ($file) = @_;

    my $raw_text = read_file($file);
    my ($raw_meta, $body) = split("\n\n", $raw_text, 2);

    my $meta = _parse_meta($raw_meta);

    my $format = $meta->{format} || detect_format($file);
    my $text   = format_text($body, $format);

    my $update_at = time2str('%c', mtime($file));
    my $pubdate   = time2str('%a, %d %b %Y %H:%M:%S %z', mtime($file));

    return {
        text        => $text,
        update_at   => $update_at,
        pubdate     => $pubdate,
        title       => $meta->{title} // '',
        description => $meta->{description} // '',
        author      => $meta->{author} // '',
        tags        => $meta->{tags} // '',
        layout      => $meta->{layout} // '',
        format      => $meta->{format} // '',
    };
}

sub _parse_meta {
    my ($raw_meta) = @_;

    my ($title, %meta);
    for (split /\n/, $raw_meta) {
        if (my ($key, $value) = m{^meta-(\w+):\s*(.+)\s*$}) {
            $meta{$key} = $value;
        }
        else {
            $title = $_;
        }
    }

    return {
        title => $title,
        %meta
    }
}

sub is_text {
    my ($file) = @_;
    return !!detect_format($file);
} 

sub detect_format {
    my ($file) = @_;

    my ($ext) = $file =~ m!\.([^.]+)$!;
    return $ext eq 'md'       ? 'markdown'
         : $ext eq 'markdown' ? 'markdown'
         : $ext eq 'txt'      ? 'hatena'
         : $ext eq 'html'     ? 'html'
         : undef
}

sub format_text {
    my ($text, $format) = @_;

    if ($format eq 'markdown') {
        return Text::Markdown::markdown($text);
    }
    elsif ($format eq 'html') {
        return $text;
    }
    elsif ($format eq 'hatena') {
        state $xatena = Text::Xatena->new;
        my $inline    = Text::Xatena::Inline->new;
        my $html = $xatena->format( $text, inline => $inline );
        $html .= join "\n", @{ $inline->footnotes };
        return $html;
    }
    else {
        die "unsupported format: $format";
    }
}

sub layout_file {
    my ($layout) = @_;
    $layout ||= 'default';
    my $layout_file = catfile($LAYOUTS_ROOT_DIR, "$layout.html");
    if (-f $layout) {
        die "layout file is not found: $layout_file";
    }
    return $layout_file;
}

sub mtime {
    my ($file) = @_;
    return (stat($file))[9];
}

sub read_file {
    my ($file) = @_;
    local $/;
    open (my $fh, '<:utf8', $file) or die $!;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub write_file {
    my ($file, $content) = @_;
    open (my $fh, '>:encoding(utf8)', $file) or die $!;
    print $fh $content;
    close($fh);
}

sub render_string {
    my ($template, $vars) = @_;

    my $mt = Text::MicroTemplate->new(
        template    => $template,
        escape_func => sub { $_[0] }, # unescape text
    );
    my $code = $mt->code;
    my $renderer = eval <<~ "..." or die $@;
    sub {
        my \$vars = shift;
        $code->();
    }
    ...

    return $renderer->($vars);
}

