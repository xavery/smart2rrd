#!/usr/bin/perl

# Public domain

use warnings;
use strict;
use File::Find;
use Data::Dumper;
use Readonly;
use Cwd;
use Capture::Tiny ':all';
use File::Which;
use utf8;

Readonly::Scalar my $cron_seconds => 30 * 60;

Readonly::Scalar my $rrd_dir       => getcwd;
Readonly::Scalar my $png_dir       => getcwd;
Readonly::Scalar my $data_colour   => '#0000FF';
Readonly::Scalar my $worst_colour  => '#FFFF00';
Readonly::Scalar my $thresh_colour => '#FF0000';
Readonly::Scalar my $smartctl      => $ENV{'SMARTCTL'} // which('smartctl');
Readonly::Scalar my $rrdtool       => $ENV{'RRDTOOL'} // which('rrdtool');

Readonly::Hash my %wanted_attrs => (
  5   => 'Reallocated_Sector_Ct',
  1   => 'Raw_Read_Error_Rate',
  197 => 'Current_Pending_Sector',
  198 => 'Offline_Uncorrectable',
  194 => 'Temperature_Celsius',
  196 => 'Reallocated_Event_Count',
  187 => 'Uncorrectable_Error_Cnt',
  188 => 'Command_Timeout',
  189 => 'High_Fly_Writes',
  190 => 'Airflow_Temperature_Cel'
);

my @disks;

sub rrd_filename {
  my $diskid = shift;
  return "${rrd_dir}/${diskid}.rrd";
}

sub png_filename {
  my $diskid = shift;
  return "${png_dir}/${diskid}.png";
}

sub create_rrd {
  my ( $diskid, $values ) = @_;
  my $rrdfile = rrd_filename($diskid);
  return if -f $rrdfile;

  my @data_sources;
  my $heartbeat = $cron_seconds * 2;
  for ( @{$values} ) {
    my $id = $_->{id};
    push @data_sources, "DS:${id}:GAUGE:${heartbeat}:0:U",
      "DS:${id}_raw:GAUGE:${heartbeat}:0:U";
  }
  my @rrd_create = (
    $rrdtool,            'create',
    $rrdfile,            '--step',
    $cron_seconds,       @data_sources,
    'RRA:MAX:0.5:1:336', 'RRA:MAX:0.5:2:744',
    'RRA:MAX:0.5:48:365'
  );
  system(@rrd_create) == 0
    or die "rrdtool create returned with non-zero status";
}

sub save_rrd {
  my ( $diskid, $values ) = @_;
  my $rrdfile = rrd_filename($diskid);
  -f $rrdfile or die "rrd file not found in save_rrd";

  my @data_sources;
  my @values;
  for ( @{$values} ) {
    my $id = $_->{id};
    push @data_sources, $id, "${id}_raw";
    push @values, $_->{value}, $_->{raw_value};
  }

  my @rrd_update = (
    $rrdtool, 'update', $rrdfile, '--template', join( ':', @data_sources ),
    '--', 'N:' . join( ':', @values )
  );
  system(@rrd_update) == 0
    or die "rrdtool update returned with non-zero status";
}

sub get_smart {
  my $disk     = shift;
  my $diskvals = [];
  open( my $fh, '-|', $smartctl, '-A', $disk );
  my $do_split = 0;
  while (<$fh>) {
    chomp;
    if (/^ID#/) {
      $do_split = 1;
      next;
    }
    next unless $do_split;
    last if $_ eq "";
    my (
      $id,     $attr_name, $flag,    $value,       $worst,
      $thresh, $type,      $updated, $when_failed, $raw_value
    ) = split;
    next if not defined( $wanted_attrs{$id} );
    push @{$diskvals},
      {
      id        => int($id),
      value     => $value,
      worst     => $worst,
      thresh    => $thresh,
      raw_value => $raw_value
      };
  }
  close($fh);
  die "smartctl returned with non-zero status" if $? != 0;
  return $diskvals;
}

sub rrd_graph {
  (
    my $diskid, my $title, my $vlabel, my $period,
    my $data_source,
    my $data_name,
    my $html, my $args
  ) = @_;
  my $pngname = "${diskid}_${data_source}_${period}";
  my $pngfile = png_filename($pngname);
  my $rrdfile = rrd_filename($diskid);
  my @graph   = (
    $rrdtool,
    'graph',
    $pngfile,
    '-a',
    'PNG',
    '--title',
    $title,
    '--vertical-label',
    $vlabel,
    '--start',
    "end-${period}",
    '--end',
    time,
    "DEF:a=${rrdfile}:${data_source}:MAX",
    "LINE1:a${data_colour}:${data_name}",
    'VDEF:alast=a,LAST',
    'GPRINT:alast:%6.2lf %s',
    @{$args}
  );
  my ( $out, $err, $rv ) = capture {
    system(@graph);
  };
  $rv == 0 or die "rrdtool graph returned with non-zero status\n$out\n$err";
  print $html "<img src=\"${pngname}.png\" alt=\"${pngname}\">\n";
}

sub generate_value_graph {
  my ( $diskid, $value, $html ) = @_;
  my $id     = $value->{id};
  my $worst  = $value->{worst};
  my $thresh = $value->{thresh};
  print $html "<hr>\n";
  for ( ( '1d', '1w', '1m' ) ) {
    rrd_graph(
      $diskid,
      $wanted_attrs{$id},
      'value', $_, $id, 'value', $html,
      [
        "HRULE:${worst}${worst_colour}:worst",
        "HRULE:${thresh}${thresh_colour}:threshold"
      ]
    );
    rrd_graph( $diskid, $wanted_attrs{$id}, 'raw', $_, "${id}_raw", 'raw',
      $html, [] );
    print $html "<br>\n";
  }
}

sub generate_graphs {
  my ( $diskid, $values, $html ) = @_;
  for ( @{$values} ) {
    generate_value_graph( $diskid, $_, $html );
  }
}

sub wanted {
  return unless /^ata-/ and not /-part\d+$/;
  my $linked = readlink;
  return unless $linked =~ /sd[a-z]$/;
  push @disks, $_;
}

sub generate_html_attr_table {
  my ( $values, $html ) = @_;
  my $table_hdr = <<HTML;
<table>
<tr>
<th>ID</th>
<th>Name</th>
<th>Value</th>
<th>Worst</th>
<th>Threshold</th>
<th>Raw value</th>
</tr>
HTML
  print $html $table_hdr;
  for ( @{$values} ) {
    my $name     = $wanted_attrs{ $_->{id} };
    my $attr_row = <<"HTML";
<tr>
<td>$_->{id}</td>
<td>${name}</td>
<td>$_->{value}</td>
<td>$_->{worst}</td>
<td>$_->{thresh}</td>
<td>$_->{raw_value}</td>
</tr>
HTML
    print $html $attr_row;
  }
  print $html "</table><br>\n";
}

find( \&wanted, '/dev/disk/by-id' );

open( my $html, '>', "${png_dir}/index.html" );
my $cur_local  = localtime;
my $htmlheader = <<"HTML";
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>SMART + RRDTool</title>
  </head>
  <body>
  Generated at ${cur_local}
HTML
print $html $htmlheader;

for my $diskid (@disks) {
  my $values = get_smart("/dev/disk/by-id/${diskid}");
  create_rrd( $diskid, $values );
  save_rrd( $diskid, $values );
  print $html "<h1>${diskid}</h1>\n";
  generate_html_attr_table( $values, $html );
  generate_graphs( $diskid, $values, $html );
}
print $html "</body>\n</html>\n";
close($html);
