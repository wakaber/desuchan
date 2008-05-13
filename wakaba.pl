#!/usr/bin/perl

use CGI::Carp qw(fatalsToBrowser); # Dump all errors to the browser window.

use strict;

use CGI::Fast;
use DBI;

#
# Import settings
#

use lib '.';
BEGIN { require "config.pl"; }
BEGIN { require "config_defaults.pl"; }
BEGIN { require "strings_en.pl"; }		# edit this line to change the language
BEGIN { require "futaba_style.pl"; }						
#BEGIN { require "captcha.pl"; }
BEGIN { require "wakautils.pl"; }

#
# Global init
#

my $protocol_re=qr/(?:http|https|ftp|mailto|nntp|aim|AIM)/;
my $dbh;


my ($has_encode);

if(CONVERT_CHARSETS)
{
	eval 'use Encode qw(decode encode)';
	$has_encode=1 unless($@);
}


return 1 if(caller); # stop here if we're being called externally

my ($query, $board);
my $count = 0;
my $handling_request = 0;
my $exit_requested = 0;
my $maximum_allowed_loops = MAX_FCGI_LOOPS;

#
# Error Management
#

sub make_error($;$$)
{
	my ($error,$fromwindow)=@_;

	make_http_header();

	my $response = (!$fromwindow) ? encode_string(ERROR_TEMPLATE->(error=>$error,stylesheets=>get_stylesheets(),board=>$board)) : encode_string(ERROR_TEMPLATE_MINI->(error=>$error,stylesheets=>get_stylesheets(),board=>$board));
	print $response;

	if(ERRORLOG) # could print even more data, really.
	{
		open ERRORFILE,'>>'.ERRORLOG;
		print ERRORFILE $error."\n";
		print ERRORFILE $ENV{HTTP_USER_AGENT}."\n";
		print ERRORFILE "**\n";
		close ERRORFILE;
	}

	# delete temp files

	last if $count > $maximum_allowed_loops;
	next; # Cancel current action that called me; go to the start of the FastCGI loop.
}

#
# Signal Trapping -- Thanks FastCGI.com FAQ
#

sub sig_handler { 
	$exit_requested = 1;
	exit(0) if !$handling_request;
}

$SIG{USR1} = \&sig_handler;
$SIG{TERM} = \&sig_handler;
$SIG{PIPE} = 'IGNORE';

#
# Database
#

sub get_conn() {
    return $MyPackage::dbh if ($MyPackage::dbh && $MyPackage::dbh->ping);

    # we don't have connection or the connection timed out, so make a new one
    return 0 unless $MyPackage::dbh = DBI->connect(SQL_DBI_SOURCE,SQL_USERNAME,SQL_PASSWORD,{AutoCommit=>1});
    return $MyPackage::dbh;
}

#
# Cache page creation
#

sub build_cache()
{
	my ($sth,$row,@thread);
	my $page=0;
	
	# grab all posts, in thread order, starting with the stickies
	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." ORDER BY stickied DESC, lasthit DESC, CASE parent WHEN 0 THEN num ELSE parent END ASC, num ASC;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);

	$row=get_decoded_hashref($sth);

	if(!$row) # no posts on the board!
	{
		build_cache_page(0,1); # make an empty page 0
	}
	else
	{
		my @threads;
		my @thread=($row);

		while($row=get_decoded_hashref($sth))
		{
			if(!$$row{parent})
			{
				push @threads,{posts=>[@thread]};
				@thread=($row); # start new thread
			}
			else
			{
				push @thread,$row;
			}
		}
		push @threads,{posts=>[@thread]};

		my $total=get_page_count(scalar @threads);
		my @pagethreads;
		while(@pagethreads=splice @threads,0,$board->option('IMAGES_PER_PAGE'))
		{
			build_cache_page($page,$total,@pagethreads);
			$page++;
		}
	}

	# check for and remove old pages
	while(-e $board->path().'/'.$page.PAGE_EXT)
	{
		unlink $board->path().'/'.$page.PAGE_EXT;
		$page++;
	}
	
	$sth->finish();
}

sub build_cache_page($$@)
{
	my ($page,$total,@threads)=@_;
	my ($filename,$tmpname);

	if($page==0) { $filename=$board->path().'/'.$board->option('HTML_SELF'); }
	else { $filename=$board->path().'/'.$page.PAGE_EXT; }

	# do abbrevations and such
	foreach my $thread (@threads)
	{
		# split off the parent post, and count the replies and images
		my ($parent,@replies)=@{$$thread{posts}};
		my $replies=@replies;
		my $images=grep { $$_{image} } @replies;
		my $curr_replies=$replies;
		my $curr_images=$images;
		my $max_replies=$board->option('REPLIES_PER_THREAD');
		my $max_images=($board->option('IMAGE_REPLIES_PER_THREAD') or $images);

		# drop replies until we have few enough replies and images
		while($curr_replies>$max_replies or $curr_images>$max_images)
		{
			my $post=shift @replies;
			$curr_images-- if($$post{image});
			$curr_replies--;
		}

		# write the shortened list of replies back
		$$thread{posts}=[$parent,@replies];
		$$thread{omit}=$replies-$curr_replies;
		$$thread{omitimages}=$images-$curr_images;

		# abbreviate the remaining posts
		foreach my $post (@{$$thread{posts}})
		{
			my $abbreviation=abbreviate_html($$post{comment},$board->option('MAX_LINES_SHOWN'),$board->option('APPROX_LINE_LENGTH'));
			if($abbreviation)
			{
				$$post{comment}=$abbreviation;
				$$post{abbrev}=1;
			}
		}
	}

	# make the list of pages
	my @pages=map +{ page=>$_ },(0..$total-1);
	foreach my $p (@pages)
	{
		if($$p{page}==0) { $$p{filename}=expand_filename($board->option('HTML_SELF')) } # first page
		else { $$p{filename}=expand_filename($$p{page}.PAGE_EXT) }
		if($$p{page}==$page) { $$p{current}=1 } # current page, no link
	}

	my ($prevpage,$nextpage);
	$prevpage=$pages[$page-1]{filename} if($page!=0);
	$nextpage=$pages[$page+1]{filename} if($page!=$total-1);

	print_page($filename,PAGE_TEMPLATE->(
		pages=>\@pages,
		postform=>($board->option('ALLOW_TEXTONLY') or $board->option('ALLOW_IMAGES')),
		image_inp=>$board->option('ALLOW_IMAGES'),
		textonly_inp=>($board->option('ALLOW_IMAGES') and $board->option('ALLOW_TEXTONLY')),
		prevpage=>$prevpage,
		nextpage=>$nextpage,
		threads=>\@threads,
		stylesheets=>get_stylesheets('board'),
		board=>$board
	));
}

sub build_thread_cache($)
{
	my ($thread)=@_;
	my ($sth,$row,@thread);
	my ($filename,$tmpname);

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=? OR parent=? ORDER BY num ASC;") or make_error(S_SQLFAIL);
	$sth->execute($thread,$thread) or make_error(S_SQLFAIL);

	while($row=get_decoded_hashref($sth)) { push(@thread,$row); }
	
	$sth->finish();

	make_error(S_NOTHREADERR) if($thread[0]{parent});

	$filename=$board->path().'/'.$board->option('RES_DIR').$thread.PAGE_EXT;

	print_page($filename,PAGE_TEMPLATE->(
		threads=>[{posts=>\@thread}],
		thread=>$thread,
		postform=>($board->option('ALLOW_TEXT_REPLIES') or $board->option('ALLOW_IMAGE_REPLIES')),
		image_inp=>$board->option('ALLOW_IMAGE_REPLIES'),
		textonly_inp=>0,
		dummy=>$thread[$#thread]{num},
		lockedthread=>$thread[0]{locked},
		stylesheets=>get_stylesheets('thread'),
		board=>$board
	));
}

sub print_page($$)
{
	my ($filename,$contents)=@_;

	$contents=encode_string($contents);
#		$PerlIO::encoding::fallback=0x0200 if($has_encode);
#		binmode PAGE,':encoding('.CHARSET.')' if($has_encode);

	if(USE_TEMPFILES)
	{
		my $tmpname=$board->path().'/'.$board->option('RES_DIR').'tmp'.int(rand(1000000000));

		open (PAGE,">$tmpname") or make_error(S_NOTWRITE);
		print PAGE $contents;
		close PAGE;

		rename $tmpname,$filename;
	}
	else
	{
		open (PAGE,">$filename") or make_error(S_NOTWRITE);
		print PAGE $contents;
		close PAGE;
	}
	
	chmod 0644, $filename; # Make world-readable
	
}

sub build_thread_cache_all()
{
	my ($sth,$row,@thread);

	$sth=$dbh->prepare("SELECT num FROM ".$board->option('SQL_TABLE')." WHERE parent=0;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);

	while($row=$sth->fetchrow_arrayref())
	{
		build_thread_cache($$row[0]);
	}
	
	$sth->finish();
}

#
# Posting
#

sub post_stuff($$$$$$$$$$$$$$$$$)
{
	my ($parent,$name,$email,$subject,$comment,$file,$uploadname,$password,$nofile,$captcha,$admin,$no_captcha,$no_format,$postfix,$sticky,$lock,$admin_post_mode)=@_;
	
	# get a timestamp for future use
	my $time=time();
	
	# Initialize admin_post variable--tells whether or not this post has fallen under the hand of a mod/admin
	my $admin_post = '';

	# check that the request came in as a POST, or from the command line
	make_error(S_UNJUST) if($ENV{REQUEST_METHOD} and $ENV{REQUEST_METHOD} ne "POST");

	# check whether the parent thread is stickied
	if ($parent)
	{
		my $selectsticky=$dbh->prepare("SELECT stickied, locked FROM ".$board->option('SQL_TABLE')." WHERE num=?;") or make_error(S_SQLFAIL);
		$selectsticky->execute($parent) or make_error(S_SQLFAIL);
		my $sticky_check = $selectsticky->fetchrow_hashref;
	
		if ($$sticky_check{stickied})
		{
			$sticky = 1;
		} 
		elsif (!$admin_post_mode) 
		{
			$sticky = 0;
		}
		
		# Forbid posting into locked thread
		if ($$sticky_check{locked} eq 'yes' && !$admin_post_mode)
		{
			make_error(S_THREADLOCKEDERROR);
		}
		
		$selectsticky->finish();
	}
	
	my ($username, $accounttype);
	if($admin_post_mode) # check admin password - allow both encrypted and non-encrypted
	{
		($username,$accounttype) = check_password($admin,'mpost');
		$admin_post = 'yes'; # Mark as administrative post.
	}
	else
	{
		# forbid admin-only features
		make_error(S_WRONGPASS) if($no_captcha or $no_format or ($sticky && !$parent) or $lock);

		# check what kind of posting is allowed
		if($parent)
		{
			make_error(S_NOTALLOWED) if($file and !($board->option('ALLOW_IMAGE_REPLIES')));
			make_error(S_NOTALLOWED) if(!$file and !($board->option('ALLOW_TEXT_REPLIES')));
		}
		else
		{
			make_error(S_NOTALLOWED) if($file and !($board->option('ALLOW_IMAGES')));
			make_error(S_NOTALLOWED) if(!$file and !($board->option('ALLOW_TEXTONLY')));
		}
	}
	
	if ($sticky && $parent)
	{
		my $stickyupdate=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET stickied=1 WHERE num=? OR parent=?;") or make_error(S_SQLFAIL);
		$stickyupdate->execute($parent, $parent) or make_error(S_SQLFAIL);
		$stickyupdate->finish();
	}
	
	if ($lock)
	{
		if ($parent)
		{
			my $lockupdate=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET locked='yes' WHERE num=? OR parent=?;") or make_error(S_SQLFAIL);
			$lockupdate->execute($parent, $parent) or make_error(S_SQLFAIL);
			$lockupdate->finish();
		}
		$lock='yes';
	}

	# check for weird characters
	make_error(S_UNUSUAL) if($parent=~/[^0-9]/);
	make_error(S_UNUSUAL) if(length($parent)>10);
	make_error(S_UNUSUAL) if($name=~/[\n\r]/);
	make_error(S_UNUSUAL) if($email=~/[\n\r]/);
	make_error(S_UNUSUAL) if($subject=~/[\n\r]/);

	# check for excessive amounts of text
	make_error(S_TOOLONG) if(length($name)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG) if(length($email)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG) if(length($subject)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG) if(length($comment)>($board->option('MAX_COMMENT_LENGTH')));

	# check to make sure the user selected a file, or clicked the checkbox
	make_error(S_NOPIC) if(!$parent and !$file and !$nofile);

	# check for empty reply or empty text-only post
	make_error(S_NOTEXT) if($comment=~/^\s*$/ and !$file);

	# get file size, and check for limitations.
	my $size=get_file_size($file) if($file);

	# find IP
	my $ip=$ENV{REMOTE_ADDR};

	#$host = gethostbyaddr($ip);
	my $numip=dot_to_dec($ip);

	# set up cookies
	my $c_name=$name;
	my $c_email=$email;
	my $c_password=$password;

	# check if IP is whitelisted
	my $whitelisted=is_whitelisted($numip);

	# process the tripcode - maybe the string should be decoded later
	my $trip;
	($name,$trip)=process_tripcode($name,($board->option('TRIPKEY')),SECRET,CHARSET);

	# check for bans
	ban_check($numip,$c_name,$subject,$comment) unless $whitelisted;

	# spam check
	spam_engine(
		query=>$query,
		trap_fields=>$board->option('SPAM_TRAP')?["name","link"]:[],
		spam_files=>[SPAM_FILES],
		charset=>CHARSET,
	) unless $whitelisted;

	# check captcha
	check_captcha($dbh,$captcha,$ip,$parent) if($board->option('ENABLE_CAPTCHA') and !$no_captcha and !is_trusted($trip));

	# proxy check
	proxy_check($ip) if (!$whitelisted and $board->option('ENABLE_PROXY_CHECK'));

	# check if thread exists, and get lasthit value
	my ($parent_res,$lasthit);
	if($parent)
	{
		$parent_res=get_parent_post($parent) or make_error(S_NOTHREADERR);
		$lasthit=$$parent_res{lasthit};
	}
	else
	{
		$lasthit=$time;
	}


	# kill the name if anonymous posting is being enforced
	if($board->option('FORCED_ANON'))
	{
		$name='';
		$trip='';
		if($email=~/sage/i) { $email='sage'; }
		else { $email=''; }
	}

	# clean up the inputs
	$email=clean_string(decode_string($email,CHARSET));
	$subject=clean_string(decode_string($subject,CHARSET));

	# check subject field for 'noko' (legacy)
	my $noko = 0;
	if ($subject =~ m/^noko$/i)
	{
		$subject = '';
		$noko = 1;
	}
	# and the link field (proper)
	elsif ($email =~ m/^noko$/i)
	{
		$noko = 1;
	}
	
	# fix up the email/link
	$email="mailto:$email" if $email and $email!~/^$protocol_re:/;

	# format comment
	$comment=format_comment(clean_string(decode_string($comment,CHARSET))) unless $no_format;
	$comment.=$postfix;

	# insert default values for empty fields
	$parent=0 unless $parent;
	$name=make_anonymous($ip,$time) unless $name or $trip;
	$subject=$board->option('S_ANOTITLE') unless $subject;
	$comment=$board->option('S_ANOTEXT') unless $comment;

	# flood protection - must happen after inputs have been cleaned up
	flood_check($numip,$time,$comment,$file,1,0);

	# Manager and deletion stuff - duuuuuh?

	# generate date
	my $date=make_date($time+TIME_OFFSET,DATE_STYLE);

	# generate ID code if enabled
	$date.=' ID:'.make_id_code($ip,$time,$email) if($board->option('DISPLAY_ID'));

	# copy file, do checksums, make thumbnail, etc
	my ($filename,$md5,$width,$height,$thumbnail,$tn_width,$tn_height)=process_file($file,$uploadname,$time,$parent) if($file);

	$sticky = 0 if (!$sticky);
	
	# finally, write to the database
	my $sth=$dbh->prepare("INSERT INTO ".$board->option('SQL_TABLE')." VALUES(null,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'','',?,?,?);") or make_error(S_SQLFAIL);
	$sth->execute($parent,$time,$lasthit,$numip,
	$date,$name,$trip,$email,$subject,$password,$comment,
	$filename,$size,$md5,$width,$height,$thumbnail,$tn_width,$tn_height,$admin_post,$sticky,$lock) or make_error(S_SQLFAIL);

	if($parent) # bumping
	{
		# check for sage, or too many replies
		unless($email=~/sage/i or sage_count($parent_res)>$board->option('MAX_RES'))
		{
			$sth=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET lasthit=$time WHERE num=? OR parent=?;") or make_error(S_SQLFAIL);
			$sth->execute($parent,$parent) or make_error(S_SQLFAIL);
		}
	}

	# remove old threads from the database
	trim_database();

	# update the cached HTML pages
	build_cache();
	
	# update the individual thread cache
	if($parent) { build_thread_cache($parent); }
	else # must find out what our new thread number is
	{
		if($filename)
		{
			$sth=$dbh->prepare("SELECT num FROM ".$board->option('SQL_TABLE')." WHERE image=?;") or make_error(S_SQLFAIL);
			$sth->execute($filename) or make_error(S_SQLFAIL);
		}
		else
		{
			$sth=$dbh->prepare("SELECT num FROM ".$board->option('SQL_TABLE')." WHERE timestamp=? AND comment=?;") or make_error(S_SQLFAIL);
			$sth->execute($time,$comment) or make_error(S_SQLFAIL);
		}
		my $num=($sth->fetchrow_array())[0];

		if($num)
		{
			# add staff log entry
			add_log_entry($username,'admin_post',$board->path().','.$num,$date,$numip,0,$time) if($admin_post_mode);
			
			build_thread_cache($num);
			$parent = $num; # For use with "noko" below
		}
	}
	
	# set the name, email and password cookies
	make_cookies(name=>$c_name,email=>$c_email,password=>$c_password,
	-charset=>CHARSET,-autopath=>$board->option('COOKIE_PATH')); # yum!
	
	if (!$admin_post_mode)
	{
		# forward back to the main page
		make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT) unless $noko;
		
		# ...unless we have "noko" (a la 4chan)--then forward to thread
		# ($parent contains current post number if a new thread was posted)
		make_http_forward($board->path().'/'.$board->option('RES_DIR').$parent.PAGE_EXT,ALTERNATE_REDIRECT);
	}
	else
	{
		# forward back to the mod panel
		make_http_forward(get_secure_script_name().'?task=mpanel&board='.$board->path(),ALTERNATE_REDIRECT) unless $noko;
		
		# ...unless we have "noko"--then forward to thread view
		make_http_forward(get_secure_script_name().'?task=mpanel&board='.$board->path()."&page=t".$parent,ALTERNATE_REDIRECT);
	}
	
	$sth->finish();
}

#
# Editing
#

sub edit_window($$$$) # ADDED subroutine for creating the post-edit window
{
	my ($num, $password, $admin, $admin_editing_mode)=@_;
	my @loop;
	my $sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=?;");
	$sth->execute($num);
	check_password($admin, 'mpanel', 1) if $admin;

	while (my $row = get_decoded_hashref($sth))
	{
		make_error(S_NOPASS,1) if ($$row{password} eq '' && !$admin_editing_mode);
		make_error(S_BADEDITPASS,1) if ($$row{password} ne $password && !$admin_editing_mode);
		make_error(S_THREADLOCKEDERROR,1) if ($$row{locked} eq 'yes' && !$admin_editing_mode);
		make_error(S_WRONGPASS,1) if ($$row{admin_post} eq 'yes' && !$admin_editing_mode);
		push @loop, $row;
	}

	$sth->finish();
	
	return if (!@loop);
	make_http_header();
	print encode_string(POST_EDIT_TEMPLATE->(admin=>$admin_editing_mode, password=>$password, loop=>\@loop, stylesheets=>get_stylesheets(),board=>$board)); 
}

sub tag_killa($) # subroutine for stripping HTML tags and supplanting them with corresponding wakabamark
{
	my $tag_killa = $_[0];
	study $tag_killa; # Prepare string for some extensive regexp.

	$tag_killa =~ s/<p><small><strong> Oekaki post<\/strong> \(Time\:.*?<\/small><\/p>//; # Strip Oekaki postfix.
	$tag_killa =~ s/<p><small><strong> Edited in Oekaki<\/strong> \(Time\:.*?<\/small><\/p>//; # Strip Oekaki edit postfix
	$tag_killa =~ s/<br\s?\/?>/\n/g;
	$tag_killa =~ s/<\/p>$//;
	$tag_killa =~ s/<\/p>/\n\n/g;
	$tag_killa =~ s/<code>([^\n]*?)<\/code>/\`$1\`/g;
	$tag_killa =~ s/<\/blockquote>$//;
	$tag_killa =~ s/<\/blockquote>/\n\n/g;
	while($tag_killa =~ m/<\s*?code>(.*?)<\/\s*?code>/s)
	{
		my $replace = $1; # String to substitute
		my @strings = split (/\n/, $replace);
		my $replace2; # String that will be substituted in
		foreach (@strings)
		{
			$replace2 .= '    '.$_."\n";
		}
		$tag_killa =~ s/<\s*?code>$replace<\/\s*?code>/$replace2\n/s;
	}
	while ($tag_killa =~ m/<ul>(.*?)<\/ul>/)
	{
		my $replace = $1;
		my $replace2 = $replace;
		my @strings = split (/<\/li>/, $replace2);
		foreach my $entry (@strings)
		{
			$entry =~ s/<li>/\* /;
		}
		$replace2 = join ("\n", @strings);
		$tag_killa =~ s/<ul>$replace<\/ul>/$replace2\n\n/gs;
	}
	while ($tag_killa =~ m/<ol>(.*?)<\/ol>/)
	{
		my $replace = $1;
		my $replace2 = $replace;
		my @strings = split (/<\/li>/, $replace2);
		my $count = 0;
		foreach my $entry (@strings)
		{
			$count++;
			$entry =~ s/<li>/$count\. /;
		}
		$replace2 = join ("\n", @strings);
		$tag_killa =~ s/<ol>$replace<\/ol>/$replace2\n\n/gs;
	}	
	$tag_killa =~ s/<\/?em>/\*/g;
	$tag_killa =~ s/<\/?strong>/\*\*/g;
	$tag_killa =~ s/<.*?>//g;
	$tag_killa;
}
	

sub password_window($$$)
{
	my ($num,$admin_post,$type) = @_;
	make_http_header();
	if ($type eq "edit")
	{
		print encode_string(PASSWORD->(num=>$num, admin_post=>$admin_post, stylesheets=>get_stylesheets(), board=>$board));
	} 
	else # Deleting
	{
		print encode_string(DELPASSWORD->(num=>$num, stylesheets=>get_stylesheets(), board=>$board));
	}
}
	

sub edit_shit($$$$$$$$$$$$$$$) # ADDED subroutine for post editing
{
	my ($num,$name,$email,$subject,$comment,$file,$uploadname,$password,$captcha,$admin,$no_captcha,$no_format,$postfix,$killtrip,$admin_editing_mode)=@_;
	# get a timestamp for future use
	my $time=time();                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            
	
	my $admin_post = '';
			# Variable to declare whether this is an admin-edited post.
			# (This is done to lock-out users from editing something edited by a mod.)
	
	# Grab original information from the target post
	my $select=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num = ?;");
	$select->execute($num);
	
	my $row = get_decoded_hashref($select);
	
	# check that the thread is not locked
	make_error(S_THREADLOCKEDERROR,1) if ($$row{locked} eq 'yes' && !$admin_editing_mode);
	
	# check that the request came in as a POST, or from the command line
	make_error(S_UNJUST,1) if($ENV{REQUEST_METHOD} and $ENV{REQUEST_METHOD} ne "POST");

	my ($username,$accounttype);
	if($admin_editing_mode) # check admin password - allow both encrypted and non-encrypted
	{
		($username, $accounttype) = check_password($admin, 'mpanel', 1);
		$admin_post = 'yes';
	}
	else
	{
		# forbid admin-only features or editing an admin post
		make_error(S_WRONGPASS,1) if($no_captcha or $no_format or $$row{admin_post} eq 'yes');
		
		# No password = No editing. (Otherwise, chaos could ensue....)
		make_error(S_NOPASS,1) if ($$row{password} eq '');
	
		# Check password.
		make_error(S_BADEDITPASS,1) if ($$row{password} ne $password);

		# check what kind of posting is allowed
		if($$row{parent})
		{
			make_error(S_NOTALLOWED,1) if($file and !($board->option('ALLOW_IMAGE_REPLIES')));
		}
		else
		{
			make_error(S_NOTALLOWED,1) if($file and !$board->option('ALLOW_IMAGES'));
		}
		
		# Only staff can change management posts and edits
		make_error("Only management can edit this.",1) if ($$row{admin_post} eq 'yes');
	}

	# check for weird characters
	make_error(S_UNUSUAL,1) if($name=~/[\n\r]/);
	make_error(S_UNUSUAL,1) if($email=~/[\n\r]/);
	make_error(S_UNUSUAL,1) if($subject=~/[\n\r]/);

	# check for excessive amounts of text
	make_error(S_TOOLONG,1) if(length($name)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG,1) if(length($email)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG,1) if(length($subject)>($board->option('MAX_FIELD_LENGTH')));
	make_error(S_TOOLONG,1) if(length($comment)>($board->option('MAX_COMMENT_LENGTH')));

	# check for empty reply or empty text-only post
	make_error(S_NOTEXT,1) if($comment=~/^\s*$/ and !$file and !$$row{filename});

	# get file size, and check for limitations.
	my $size=get_file_size($file) if($file);

	# find IP
	my $ip=$ENV{REMOTE_ADDR};

	#$host = gethostbyaddr($ip);
	my $numip=dot_to_dec($ip);

	# set up cookies
	my $c_name=$name;
	my $c_email=$email;
	my $c_password=$password;

	# check if IP is whitelisted
	my $whitelisted=is_whitelisted($numip);

	# process the tripcode - maybe the string should be decoded later
	my $trip;
	($name,$trip)=process_tripcode($name,$board->option('TRIPKEY'),SECRET,CHARSET);
	$trip = '' if $killtrip;

	# check for bans
	ban_check($numip,$c_name,$subject,$comment) unless $whitelisted;

	# spam check
	spam_engine(
		query=>$query,
		trap_fields=>$board->option('SPAM_TRAP')?["name","link"]:[],
		spam_files=>[SPAM_FILES],
		charset=>CHARSET,
	) unless $whitelisted;

	# check captcha
	check_captcha($dbh,$captcha,$ip,$$row{parent}) if($board->option('ENABLE_CAPTCHA') and !$no_captcha and !is_trusted($trip));

	# proxy check
	proxy_check($ip) if (!$whitelisted and $board->option('ENABLE_PROXY_CHECK'));

	# kill the name if anonymous posting is being enforced
	if($board->option('FORCED_ANON'))
	{
		$name='';
		$trip='';
		if($email=~/sage/i) { $email='sage'; }
		else { $email=''; }
	}

	# clean up the inputs
	$email=clean_string(decode_string($email,CHARSET));
	$subject=clean_string(decode_string($subject,CHARSET));

	# fix up the email/link
	$email="mailto:$email" if $email and $email!~/^$protocol_re:/;

	# format comment
	$comment=format_comment(clean_string(decode_string($comment,CHARSET))) unless $no_format;
	
	# check for past oekaki postfix and attach it to the current comment if necessary
	if (!$postfix && !$admin_editing_mode && !$file)
	{
		if ($$row{comment} =~ m/(<p><small><strong>\s*(Oekaki post|Edited in Oekaki)\s*<\/strong> \(Time\:.*?<\/small><\/p>)/)
		{
			$comment.=$1;
		}
	}
	elsif ($file && $postfix)
	{
		if ($$row{comment} =~ m/(<p><small><strong>\s*Oekaki post\s*<\/strong> \(Time\:.*?<\/small><\/p>)/)
		{
			my $oekaki_original = $1;
			$oekaki_original =~ s/<\/small><\/p>//;
			$comment.=$oekaki_original;
			$postfix =~ s/<p><small><strong>/<br \/><strong>/;
		}
		$comment.=$postfix;
	}
	else
	{
		$comment.=$postfix; # If there is a file and no postfix, then we'll attach the empty variable
	}

	# insert default values for empty fields
	$name=make_anonymous($ip,$time) unless $name or $trip;
	$subject=$board->option('S_ANOTITLE') unless $subject;
	$comment=$board->option('S_ANOTEXT') unless $comment;

	# flood protection - must happen after inputs have been cleaned up
	flood_check($numip,$time,$comment,$file,0,0);

	# Manager and deletion stuff - duuuuuh?

	# generate date
	my $date=make_date($time+8*3600,DATE_STYLE);

	# generate ID code if enabled
	$date.=' ID:'.make_id_code($ip,$time,$email) if($board->option('DISPLAY_ID'));

	# copy file, do checksums, make thumbnail, etc
	 if($file)
	 {
		 my ($filename,$md5,$width,$height,$thumbnail,$tn_width,$tn_height)=process_file($file,$uploadname,$time,$$row{parent});
		 my $filesth=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET image=?, md5=?, width=?, height=?, thumbnail=?,tn_width=?,tn_height=? WHERE num=?")
		 	or make_error(S_SQLFAIL,1);
		 $filesth->execute($filename,$md5,$width,$height,$thumbnail,$tn_width,$tn_height, $num) or make_error(S_SQLFAIL);
		 # now delete original files
		 if ($$row{image} ne '') { unlink $$row{image}; }
		 my $thumb=$board->path.'/'.$board->option('THUMB_DIR');
		 if ($$row{thumbnail} =~ /^$thumb/) { unlink $$row{thumbnail}; }
	 }
	
	# close old dbh
	$select->finish(); 
	
	# finally, write to the database
	my $sth=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET name=?,trip=?,subject=?,email=?,comment=?,lastedit=?,lastedit_ip=?,admin_post=? WHERE num=?;") or make_error(S_SQLFAIL,1);
	$sth->execute($name,($trip || $killtrip) ? $trip : $$row{trip},$subject,$email,$comment,$date,$numip,$admin_post,$num) or make_error(S_SQLFAIL,1);

	# update the cached HTML pages
	build_cache();

	# update the individual thread cache
	if($$row{parent}) { build_thread_cache($$row{parent}); }
	else # rebuild cache for edited OP
	{
		build_thread_cache($num);
	}
	
	$sth->finish();
	
	# add staff log entry, if needed
	add_log_entry($username,'admin_edit',$board->path().','.$num,$date,$numip,0,$time) if($admin_post eq 'yes');

	# redirect to confirmation page
	make_http_header();
	print encode_string(EDIT_SUCCESSFUL->(stylesheets=>get_stylesheets(),board=>$board)); 
}

#
# Thread Management
#

sub sticky($$)
{
	my ($num, $admin) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin);

	my $sth=$dbh->prepare("SELECT parent, stickied FROM ".$board->option('SQL_TABLE')." WHERE num=? LIMIT 1;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	my $row=get_decoded_hashref($sth);
	if (!$$row{parent})
	{
		make_error(S_ALREADYSTICKIED) if $$row{stickied}; 
		my $update=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET stickied=1 WHERE num=? OR parent=?;") or make_error(S_SQLFAIL);
		$update->execute($num, $num) or make_error(S_SQLFAIL);
	}
	else
	{
		make_error(S_NOTATHREAD);
	}
	
	$sth->finish();
	
	add_log_entry($username,'thread_sticky',$board->path().','.$num,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
	
	build_thread_cache($num);
	build_cache();
	make_http_forward(get_secure_script_name()."?task=mpanel&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub unsticky($$)
{
	my ($num, $admin) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin);
	
	my $sth=$dbh->prepare("SELECT parent, stickied FROM ".$board->option('SQL_TABLE')." WHERE num=? LIMIT 1;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	my $row=get_decoded_hashref($sth);
	if (!$$row{parent})
	{
		make_error(S_NOTSTICKIED) if !$$row{stickied}; 
		my $update=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET stickied=0 WHERE num=? OR parent=?;") 
			or make_error(S_SQLFAIL);
		$update->execute($num, $num) or make_error(S_SQLFAIL);
	}
	else
	{
		make_error("A Post, Not a Thread, Was Specified.");
	}
	
	$sth->finish();
	
	add_log_entry($username,'thread_unsticky',$board->path().','.$num,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
	
	build_thread_cache($num);
	build_cache();
	make_http_forward(get_secure_script_name()."?task=mpanel&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub lock_thread($$)
{
	my ($num, $admin) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin);
	
	my $sth=$dbh->prepare("SELECT parent, locked FROM ".$board->option('SQL_TABLE')." WHERE num=? LIMIT 1;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	my $row=get_decoded_hashref($sth);
	if (!$$row{parent})
	{
		make_error(S_ALREADYLOCKED) if ($$row{locked} eq 'yes');
		my $update=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET locked='yes' WHERE num=? OR parent=?;") 
			or make_error(S_SQLFAIL);
		$update->execute($num, $num) or make_error(S_SQLFAIL);
	}
	else
	{
		make_error(S_NOTATHREAD);
	}
	
	$sth->finish();
	
	add_log_entry($username,'thread_lock',$board->path().','.$num,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
	
	build_thread_cache($num);
	build_cache();
	make_http_forward(get_secure_script_name()."?task=mpanel&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub unlock_thread($$)
{
	my ($num, $admin) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin);
	
	my $sth=$dbh->prepare("SELECT parent, locked FROM ".$board->option('SQL_TABLE')." WHERE num=? LIMIT 1;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	my $row=get_decoded_hashref($sth);

	if (!$$row{parent})
	{
		make_error("String Already Unlocked.") if ($$row{locked} ne 'yes');
		my $update=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET locked='' WHERE num=? OR parent=?;") 
			or make_error(S_SQLFAIL);
		$update->execute($num, $num) or make_error(S_SQLFAIL);
	}
	else
	{
		make_error(S_NOTATHREAD);
	}
	
	$sth->finish();
	
	add_log_entry($username,'thread_unlock',$board->path().','.$num,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
	
	build_thread_cache($num);
	build_cache();
	make_http_forward(get_secure_script_name()."?task=mpanel&board=".$board->path(),ALTERNATE_REDIRECT);
}

#
# Ban/Whitelist Checking
#

sub is_whitelisted($)
{
	my ($numip)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT count(*) FROM ".SQL_ADMIN_TABLE." WHERE type='whitelist' AND ? & ival2 = ival1 & ival2;") or make_error(S_SQLFAIL);
	$sth->execute($numip) or make_error(S_SQLFAIL);
	my $ip_is_whitelisted = ($sth->fetchrow_array())[0];
	$sth->finish();

	return 1 if($ip_is_whitelisted);

	return 0;
}

sub is_trusted($)
{
	my ($trip)=@_;
	my ($sth);
        $sth=$dbh->prepare("SELECT count(*) FROM ".SQL_ADMIN_TABLE." WHERE type='trust' AND sval1 = ?;") or make_error(S_SQLFAIL);
        $sth->execute($trip) or make_error(S_SQLFAIL);
	my $tripfag_is_trusted = ($sth->fetchrow_array())[0];
	$sth->finish();

        return 1 if($tripfag_is_trusted);

	return 0;
}

sub ban_admin_check($$)
{
	my ($ip, $admin) = @_;
	my $sth=$dbh->prepare("SELECT count(*) FROM ".SQL_ADMIN_TABLE." WHERE type='ipban' AND ? & ival2 = ival1 & ival2;") or make_error(S_SQLFAIL);
	$sth->execute($ip) or make_error(S_SQLFAIL);
	my $admin_is_banned = ($sth->fetchrow_array())[0];
	$sth->finish();
	
	admin_is_banned($ip, $admin) if ($admin_is_banned);
}

sub ban_check($$$$)
{
	my ($numip,$name,$subject,$comment)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT count(*) FROM ".SQL_ADMIN_TABLE." WHERE type='ipban' AND ? & ival2 = ival1 & ival2;") or make_error(S_SQLFAIL);
	$sth->execute($numip) or make_error(S_SQLFAIL);

	host_is_banned($numip) if (($sth->fetchrow_array())[0]);

# fucking mysql...
#	$sth=$dbh->prepare("SELECT count(*) FROM ".SQL_ADMIN_TABLE." WHERE type='wordban' AND ? LIKE '%' || sval1 || '%';") or make_error(S_SQLFAIL);
#	$sth->execute($comment) or make_error(S_SQLFAIL);
#
#	make_error(S_STRREF) if(($sth->fetchrow_array())[0]);

	$sth=$dbh->prepare("SELECT sval1 FROM ".SQL_ADMIN_TABLE." WHERE type='wordban';") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);

	my ($row, $badstring);
	while($row=$sth->fetchrow_arrayref())
	{
		my $regexp=quotemeta $$row[0];
		$badstring = 1 if($comment=~/$regexp/i);
		$badstring = 1 if($name=~/$regexp/i);
		$badstring = 1 if($subject=~/$regexp/i);
	}
	
	$sth->finish();

	make_error(S_STRREF) if $badstring;
	
	# etc etc etc

	return(0);
}

sub host_is_banned($) # subroutine for handling bans
{
	my $numip = $_[0];
	
	my $sth=$dbh->prepare("SELECT * FROM ".SQL_ADMIN_TABLE." WHERE type='ipban' AND ? & ival2 = ival1 & ival2;") or make_error(S_SQLFAIL);
	$sth->execute($numip) or make_error(S_SQLFAIL);
	
	my ($comment, $expiration);
	
	while (my $baninfo = $sth->fetchrow_hashref())
	{
		if ($comment && $comment ne '') # In the event that there are several bans affecting one IP.
						# As of this latest revision, this should only happen if both an individual IP and a range ban affect a host.
		{
			$comment .= "<br /><br />+ ".$$baninfo{comment};
		}
		else
		{			
			$comment = $$baninfo{comment};
		}
		$expiration = ($$baninfo{expiration}) ? epoch_to_human($$baninfo{expiration}) : 0 
			unless ($expiration > $$baninfo{expiration} && $$baninfo{expiration} != 0);
	}
	
	$comment = S_BAN_MISSING_REASON if ($comment eq '' || !defined($comment));
	
	my $appeal = S_BAN_APPEAL;
		
	make_http_header();

	print encode_string(BAN_TEMPLATE->(numip => dec_to_dot($numip), comment => $comment, appeal => $appeal, expiration => $expiration));
	
	$sth->finish();

	if(ERRORLOG)
	{
		open ERRORFILE,'>>'.ERRORLOG;
		print ERRORFILE S_BADHOST."\n";
		print ERRORFILE $ENV{HTTP_USER_AGENT}."\n";
		print ERRORFILE "**\n";
		close ERRORFILE;
	}

	# delete temp files

	last if $count > $maximum_allowed_loops;
	next; # Cancel current action that called me; go to the start of the FastCGI loop.
}

sub admin_is_banned($$)
{
	my ($numip, $admin) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	if ($type eq 'admin')
	{
		remove_ban_on_admin($admin); # Remove ban, go back to start of FastCGI loop.
	}
	else
	{
		make_error("Access denied due to banned host.");
	}
}

#
# Flood Checking
#

sub flood_check($$$$$$)
{
	my ($ip,$time,$comment,$file,$no_repeat,$report_check)=@_;
	my ($sth,$maxtime);
	
	$no_repeat = 0 if ($report_check);

	if($file)
	{
		# check for to quick file posts
		$maxtime=$time-( ($report_check) ? (REPORT_RENZOKU) : ($board->option('RENZOKU2')));
		$sth=$dbh->prepare("SELECT count(*) FROM ".(($report_check) ? SQL_REPORT_TABLE : $board->option('SQL_TABLE'))." WHERE ".($report_check ? "reporter=?" : "ip=?")." AND timestamp>$maxtime;") or make_error(S_SQLFAIL);
		$sth->execute($ip) or make_error(S_SQLFAIL);
		make_error(S_RENZOKU2) if(($sth->fetchrow_array())[0]);
	}
	else
	{
		# check for too quick replies or text-only posts
		$maxtime=$time-( ($report_check) ? (REPORT_RENZOKU) : ($board->option('RENZOKU')));
		$sth=$dbh->prepare("SELECT count(*) FROM ".(($report_check) ? SQL_REPORT_TABLE : $board->option('SQL_TABLE'))." WHERE ".($report_check ? "reporter=?" : "ip=?")." AND timestamp>$maxtime;") or make_error(S_SQLFAIL);
		$sth->execute($ip) or make_error(S_SQLFAIL);
		make_error(S_RENZOKU) if(($sth->fetchrow_array())[0]);

		# check for repeated messages
		if ($no_repeat) # If the post is being edited, the comment field does not have to change.
		{
			$maxtime=$time-($board->option('RENZOKU3'));
			$sth=$dbh->prepare("SELECT count(*) FROM ".$board->option('SQL_TABLE')." WHERE ip=? AND comment=? AND timestamp>$maxtime;") or make_error(S_SQLFAIL);
			$sth->execute($ip,$comment) or make_error(S_SQLFAIL);
			make_error(S_RENZOKU3) if(($sth->fetchrow_array())[0]);
		}
	}
	
	$sth->finish();
	
}

#
# Proxy Checking
#

sub proxy_check($)
{
	my ($ip)=@_;
	my ($sth);

	proxy_clean();

	# check if IP is from a known banned proxy
	$sth=$dbh->prepare("SELECT count(*) FROM ".SQL_PROXY_TABLE." WHERE type='black' AND ip = ?;") or make_error(S_SQLFAIL);
	$sth->execute($ip) or make_error(S_SQLFAIL);

	make_error(S_BADHOSTPROXY) if(($sth->fetchrow_array())[0]);

	# check if IP is from a known non-proxy
	$sth=$dbh->prepare("SELECT count(*) FROM ".SQL_PROXY_TABLE." WHERE type='white' AND ip = ?;") or make_error(S_SQLFAIL);
	$sth->execute($ip) or make_error(S_SQLFAIL);

        my $timestamp=time();
        my $date=make_date($timestamp,DATE_STYLE);

	if(($sth->fetchrow_array())[0])
	{	# known good IP, refresh entry
		$sth=$dbh->prepare("UPDATE ".SQL_PROXY_TABLE." SET timestamp=?, date=? WHERE ip=?;") or make_error(S_SQLFAIL);
		$sth->execute($timestamp,$date,$ip) or make_error(S_SQLFAIL);
	}
	else
	{	# unknown IP, check for proxy
		my $command = $board->option('PROXY_COMMAND') . " " . $ip;
		$sth=$dbh->prepare("INSERT INTO ".SQL_PROXY_TABLE." VALUES(null,?,?,?,?);") or make_error(S_SQLFAIL);

		if(`$command`)
		{
			$sth->execute('black',$ip,$timestamp,$date) or make_error(S_SQLFAIL);
			make_error(S_PROXY);
		} 
		else
		{
			$sth->execute('white',$ip,$timestamp,$date) or make_error(S_SQLFAIL);
		}
	}
	
	$sth->finish();
	
}

sub add_proxy_entry($$$$$)
{
	my ($admin,$type,$ip,$timestamp,$date)=@_;
	my ($sth);

	check_password($admin, 'proxy');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	# Verifies IP range is sane. The price for a human-readable db...
	unless ($ip =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ && $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255) {
		make_error(S_BADIP);
	}
	if ($type == 'white') { 
		$timestamp = $timestamp - $board->option('PROXY_WHITE_AGE') + time(); 
	}
	else
	{
		$timestamp = $timestamp - $board->option('PROXY_BLACK_AGE') + time(); 
	}	

	# This is to ensure user doesn't put multiple entries for the same IP
	$sth=$dbh->prepare("DELETE FROM ".SQL_PROXY_TABLE." WHERE ip=?;") or make_error(S_SQLFAIL);
	$sth->execute($ip) or make_error(S_SQLFAIL);

	# Add requested entry
	$sth=$dbh->prepare("INSERT INTO ".SQL_PROXY_TABLE." VALUES(null,?,?,?,?);") or make_error(S_SQLFAIL);
	$sth->execute($type,$ip,$timestamp,$date) or make_error(S_SQLFAIL);
	$sth->finish();

        make_http_forward(get_secure_script_name()."?task=proxy&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub proxy_clean()
{
	my ($sth,$timestamp);

	if($board->option('PROXY_BLACK_AGE') == $board->option('PROXY_WHITE_AGE'))
	{
		$timestamp = time() - $board->option('PROXY_BLACK_AGE');
		$sth=$dbh->prepare("DELETE FROM ".SQL_PROXY_TABLE." WHERE timestamp<?;") or make_error(S_SQLFAIL);
		$sth->execute($timestamp) or make_error(S_SQLFAIL);
	} 
	else
	{
		$timestamp = time() - $board->option('PROXY_BLACK_AGE');
		$sth=$dbh->prepare("DELETE FROM ".SQL_PROXY_TABLE." WHERE type='black' AND timestamp<?;") or make_error(S_SQLFAIL);
		$sth->execute($timestamp) or make_error(S_SQLFAIL);

		$timestamp = time() - $board->option('PROXY_WHITE_AGE');
		$sth=$dbh->prepare("DELETE FROM ".SQL_PROXY_TABLE." WHERE type='white' AND timestamp<?;") or make_error(S_SQLFAIL);
		$sth->execute($timestamp) or make_error(S_SQLFAIL);
	}
	
	$sth->finish();
}

sub remove_proxy_entry($$)
{
	my ($admin,$num)=@_;
	my ($sth);

	check_password($admin, 'proxy');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	$sth=$dbh->prepare("DELETE FROM ".SQL_PROXY_TABLE." WHERE num=?;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	$sth->finish();

	make_http_forward(get_secure_script_name()."?task=proxy&board=".$board->path(),ALTERNATE_REDIRECT);
}

#
# String Formatting
#

sub format_comment($)
{
	my ($comment)=@_;

	# hide >>1 references from the quoting code
	$comment=~s/&gt;&gt;([0-9\-]+)/&gtgt;$1/g;

	my $handler=sub # fix up >>1 references
	{
		my $line=shift;

		$line=~s!&gtgt;([0-9]+)!
			my $res=get_post($1);
			if($res) { '<a href="'.get_reply_link($$res{num},$$res{parent}).'" onclick="highlight('.$1.')">&gt;&gt;'.$1.'</a>' }
			else { "&gt;&gt;$1"; }
		!ge;			

		return $line;
	};

	if($board->option('ENABLE_WAKABAMARK')) { $comment=do_wakabamark($comment,$handler) }
	else { $comment="<p>".simple_format($comment,$handler)."</p>" }

	# fix <blockquote> styles for old stylesheets
	$comment=~s/<blockquote>/<blockquote class="unkfunc">/g;

	# restore >>1 references hidden in code blocks
	$comment=~s/&gtgt;/&gt;&gt;/g;

	return $comment;
}

sub simple_format($@)
{
	my ($comment,$handler)=@_;
	return join "<br />",map
	{
		my $line=$_;

		# make URLs into links
		$line=~s{(https?://[^\s<>"]*?)((?:\s|<|>|"|\.|\)|\]|!|\?|,|&#44;|&quot;)*(?:[\s<>"]|$))}{\<a href="$1"\>$1\</a\>$2}sgi;

		# colour quoted sections if working in old-style mode.
		$line=~s!^(&gt;[^_]*)$!\<span class="unkfunc"\>$1\</span\>!g unless($board->option('ENABLE_WAKABAMARK'));

		$line=$handler->($line) if($handler);

		$line;
	} split /\n/,$comment;
}

sub encode_string($)
{
	my ($str)=@_;

	return $str unless($has_encode);
	return encode(CHARSET,$str,0x0400);
}

sub make_anonymous($$)
{
	my ($ip,$time)=@_;

	return $board->option('S_ANONAME') unless($board->option('SILLY_ANONYMOUS'));

	my $string=$ip;
	$string.=",".int($time/86400) if($board->option('SILLY_ANONYMOUS')=~/day/i);
	$string.=",".$ENV{SCRIPT_NAME} if($board->option('SILLY_ANONYMOUS')=~/board/i);

	srand unpack "N",hide_data($string,4,"silly",SECRET);

	return cfg_expand("%G% %W%",
		W => ["%B%%V%%M%%I%%V%%F%","%B%%V%%M%%E%","%O%%E%","%B%%V%%M%%I%%V%%F%","%B%%V%%M%%E%","%O%%E%","%B%%V%%M%%I%%V%%F%","%B%%V%%M%%E%"],
		B => ["B","B","C","D","D","F","F","G","G","H","H","M","N","P","P","S","S","W","Ch","Br","Cr","Dr","Bl","Cl","S"],
		I => ["b","d","f","h","k","l","m","n","p","s","t","w","ch","st"],
		V => ["a","e","i","o","u"],
		M => ["ving","zzle","ndle","ddle","ller","rring","tting","nning","ssle","mmer","bber","bble","nger","nner","sh","ffing","nder","pper","mmle","lly","bling","nkin","dge","ckle","ggle","mble","ckle","rry"],
		F => ["t","ck","tch","d","g","n","t","t","ck","tch","dge","re","rk","dge","re","ne","dging"],
		O => ["Small","Snod","Bard","Billing","Black","Shake","Tilling","Good","Worthing","Blythe","Green","Duck","Pitt","Grand","Brook","Blather","Bun","Buzz","Clay","Fan","Dart","Grim","Honey","Light","Murd","Nickle","Pick","Pock","Trot","Toot","Turvey"],
		E => ["shaw","man","stone","son","ham","gold","banks","foot","worth","way","hall","dock","ford","well","bury","stock","field","lock","dale","water","hood","ridge","ville","spear","forth","will"],
		G => ["Albert","Alice","Angus","Archie","Augustus","Barnaby","Basil","Beatrice","Betsy","Caroline","Cedric","Charles","Charlotte","Clara","Cornelius","Cyril","David","Doris","Ebenezer","Edward","Edwin","Eliza","Emma","Ernest","Esther","Eugene","Fanny","Frederick","George","Graham","Hamilton","Hannah","Hedda","Henry","Hugh","Ian","Isabella","Jack","James","Jarvis","Jenny","John","Lillian","Lydia","Martha","Martin","Matilda","Molly","Nathaniel","Nell","Nicholas","Nigel","Oliver","Phineas","Phoebe","Phyllis","Polly","Priscilla","Rebecca","Reuben","Samuel","Sidney","Simon","Sophie","Thomas","Walter","Wesley","William"],
	);
}

sub make_id_code($$$)
{
	my ($ip,$time,$link)=@_;

	return $board->option('EMAIL_ID') if($link and $board->option('DISPLAY_ID')=~/link/i);
	return $board->option('EMAIL_ID') if($link=~/sage/i and $board->option('DISPLAY_ID')=~/sage/i);

	return resolve_host($ENV{REMOTE_ADDR}) if($board->option('DISPLAY_ID')=~/host/i);
	return $ENV{REMOTE_ADDR} if($board->option('DISPLAY_ID')=~/ip/i);

	my $string="";
	$string.=",".int($time/86400) if($board->option('DISPLAY_ID')=~/day/i);
	$string.=",".$ENV{SCRIPT_NAME} if($board->option('DISPLAY_ID')=~/board/i);

	return mask_ip($ENV{REMOTE_ADDR},make_key("mask",SECRET,32).$string) if($board->option('DISPLAY_ID')=~/mask/i);

	return hide_data($ip.$string,6,"id",SECRET,1);
}

#
# Post Lookup
#

sub get_post($)
{
	my ($thread)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=?;") or make_error(S_SQLFAIL);
	$sth->execute($thread) or make_error(S_SQLFAIL);
	my $return = $sth->fetchrow_hashref();
	$sth->finish();

	return ($return);
}

sub get_parent_post($)
{
	my ($thread)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=? AND parent=0;") or make_error(S_SQLFAIL);
	$sth->execute($thread) or make_error(S_SQLFAIL);
	my $return = $sth->fetchrow_hashref();
	$sth->finish();

	return $return;
}

sub sage_count($)
{
	my ($parent)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT count(*) FROM ".$board->option('SQL_TABLE')." WHERE parent=? AND NOT ( timestamp<? AND ip=? );") or make_error(S_SQLFAIL);
	$sth->execute($$parent{num},$$parent{timestamp}+($board->option('NOSAGE_WINDOW')),$$parent{ip}) or make_error(S_SQLFAIL);
	my $return = ($sth->fetchrow_array())[0];
	$sth->finish();

	return $return;
}

#
# Upload Processing
#

sub get_file_size($)
{
	my ($file)=@_;
	my (@filestats,$size);

	@filestats=stat $file;
	$size=$filestats[7];

	make_error(S_TOOBIG) if($size>($board->option('MAX_KB'))*1024);
	make_error(S_TOOBIGORNONE) if($size==0); # check for small files, too?

	return($size);
}

sub process_file($$$$)
{
	my ($file,$uploadname,$time,$parent)=@_;
	my $filetypes=$board->option('FILETYPES');

	# make sure to read file in binary mode on platforms that care about such things
	binmode $file;

	# analyze file and check that it's in a supported format
	my ($ext,$width,$height)=analyze_image($file,$uploadname);

	my $known=($width or $$filetypes{$ext});

	make_error(S_BADFORMAT) unless($board->option('ALLOW_UNKNOWN') or $known);
	make_error(S_BADFORMAT) if(grep { $_ eq $ext } $board->option('FORBIDDEN_EXTENSIONS'));
	make_error(S_TOOBIG) if($board->option('MAX_IMAGE_WIDTH') and $width>($board->option('MAX_IMAGE_WIDTH')));
	make_error(S_TOOBIG) if($board->option('MAX_IMAGE_HEIGHT') and $height>($board->option('MAX_IMAGE_HEIGHT')));
	make_error(S_TOOBIG) if($board->option('MAX_IMAGE_PIXELS') and $width*$height>($board->option('MAX_IMAGE_PIXELS')));

	# generate random filename - fudges the microseconds
	my $filebase=$time.sprintf("%03d",int(rand(1000)));
	my $filename=$board->path.'/'.$board->option('IMG_DIR').$filebase.'.'.$ext;
	my $thumbnail=$board->path.'/'.$board->option('THUMB_DIR').$filebase."s.jpg";
	$filename.=$board->option('MUNGE_UNKNOWN') unless($known);

	# do copying and MD5 checksum
	my ($md5,$md5ctx,$buffer);

	# prepare MD5 checksum if the Digest::MD5 module is available
	eval 'use Digest::MD5 qw(md5_hex)';
	$md5ctx=Digest::MD5->new unless($@);

	# copy file
	open (OUTFILE,">>$filename") or make_error(S_NOTWRITE);
	binmode OUTFILE;
	while (read($file,$buffer,1024)) # should the buffer be larger?
	{
		print OUTFILE $buffer;
		$md5ctx->add($buffer) if($md5ctx);
	}
	close $file;
	close OUTFILE;

	if($md5ctx) # if we have Digest::MD5, get the checksum
	{
		$md5=$md5ctx->hexdigest();
	}
	else # otherwise, try using the md5sum command
	{
		my $md5sum=`md5sum $filename`; # filename is always the timestamp name, and thus safe
		($md5)=$md5sum=~/^([0-9a-f]+)/ unless($?);
	}

	if($md5 && (($parent && $board->option('DUPLICATE_DETECTION') eq 'thread') || $board->option('DUPLICATE_DETECTION') eq 'board')) # if we managed to generate an md5 checksum, check for duplicate files
	{
		my $sth;
		
		if ($board->option('DUPLICATE_DETECTION') eq 'thread') # Check dupes in same thread
		{
			$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE md5=? AND (parent=? OR num=?);") or make_error(S_SQLFAIL);
			$sth->execute($md5, $parent, $parent) or make_error(S_SQLFAIL);
		}
		else # Check dupes throughout board
		{
			$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE md5=?;") or make_error(S_SQLFAIL);
			$sth->execute($md5) or make_error(S_SQLFAIL);
		}
		
		if(my $match=$sth->fetchrow_hashref())
		{
			unlink $filename; # make sure to remove the file
			make_error(sprintf(S_DUPE,get_reply_link($$match{num},$parent)));
		}
		
		$sth->finish();
	}

	# do thumbnail
	my ($tn_width,$tn_height,$tn_ext);

	if(!$width) # unsupported file
	{
		if($$filetypes{$ext}) # externally defined filetype
		{
			open THUMBNAIL,$board->path().'/'.$$filetypes{$ext};
			binmode THUMBNAIL;
			($tn_ext,$tn_width,$tn_height)=analyze_image(\*THUMBNAIL,$$filetypes{$ext});
			close THUMBNAIL;

			# was that icon file really there?
			if(!$tn_width) { $thumbnail=undef }
			else { $thumbnail=$$filetypes{$ext} }
		}
		else
		{
			$thumbnail=undef;
		}
	}
	elsif($width>($board->option('MAX_W')) or $height>($board->option('MAX_H')) or $board->option('THUMBNAIL_SMALL'))
	{
		if($width<=($board->option('MAX_W')) and $height<=($board->option('MAX_H')))
		{
			$tn_width=$width;
			$tn_height=$height;
		}
		else
		{
			$tn_width=$board->option('MAX_W');
			$tn_height=int(($height*($board->option('MAX_W')))/$width);

			if($tn_height>($board->option('MAX_H')))
			{
				$tn_width=int(($width*($board->option('MAX_H')))/$height);
				$tn_height=$board->option('MAX_H');
			}
		}

		if($board->option('STUPID_THUMBNAILING')) { $thumbnail=$filename }
		else
		{
			$thumbnail=undef unless(make_thumbnail($filename,$thumbnail,$tn_width,$tn_height,$board->option('THUMBNAIL_QUALITY'),$board->option('CONVERT_COMMAND')));
		}
	}
	else
	{
		$tn_width=$width;
		$tn_height=$height;
		$thumbnail=$filename;
	}

	if($$filetypes{$ext} && (($ext ne 'gif' && $ext ne 'jpg' && $ext ne 'png') || $$filetypes{$ext} eq '.')) # externally defined filetype - restore the name
	{
		my $newfilename=$uploadname;
		$newfilename=~s!^.*[\\/]!!; # cut off any directory in filename
		$newfilename=$board->path().'/'.$board->option('IMG_DIR').$newfilename;

		unless(-e $newfilename) # verify no name clash
		{
			rename $filename,$newfilename;
			$thumbnail=$newfilename if($thumbnail eq $filename);
			$filename=$newfilename;
		}
		else
		{
			unlink $filename;
			make_error(S_DUPENAME);
		}
	}

        if($board->option('ENABLE_LOAD'))
        {       # only called if files to be distributed across web     
                $ENV{SCRIPT_NAME}=~m!^(.*/)[^/]+$!;
		my $root=$1;
                system($board->option('LOAD_SENDER_SCRIPT')." $filename $root $md5 &");
        }
	
	chmod 0644, $filename; # Make file world-readable
	chmod 0644, $thumbnail if defined($thumbnail); # Make thumbnail (if any) world-readable
	
	my $board_path = $board->path(); # Clear out the board path name.
	$filename =~ s/^${board_path}\///;
	$thumbnail =~ s/^${board_path}\///;
	
	return ($filename,$md5,$width,$height,$thumbnail,$tn_width,$tn_height);
}

#
# Deleting
#

sub delete_stuff($$$$$$@)
{
	my ($password,$fileonly,$archive,$admin,$admin_deletion_mode,$caller,@posts)=@_;
	my ($username, $type,$post,$ip);

	if($admin_deletion_mode)
	{
		($username, $type) = check_password($admin, 'mpanel');
		ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));
	}
	
	make_error(S_BADDELPASS) unless($password or $admin); # refuse empty password immediately

	# no password means delete always
	$password="" if($admin_deletion_mode); 

	foreach $post (@posts)
	{
		$ip = delete_post($post,$password,$fileonly,$archive);
		if($admin_deletion_mode && $ip)
		{
			add_log_entry($username,'admin_delete',$board->path().','.$post.' (Poster IP '.$ip.')'.(($fileonly) ? ' (File Only)' : ''),make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
			if ($caller ne 'internal') # If not called by mark_resolved() itself...
			{
				my $reportcheck = $dbh->prepare("SELECT * FROM ".SQL_REPORT_TABLE." WHERE postnum=? LIMIT 1");
				$reportcheck->execute($post);
				my $current_board_name = $board->path();
				mark_resolved($admin,'','internal',($current_board_name=>[$post])) if (($reportcheck->fetchrow_array())[0]);
			}
		}
	}
	
	# update the cached HTML pages
	build_cache();
	if ($caller eq 'internal')
	{ return; } # If not called directly, return to the calling function
	elsif($admin_deletion_mode)
	{ make_http_forward(get_secure_script_name()."?task=mpanel&board=".$board->path(),ALTERNATE_REDIRECT); }
	elsif ($caller eq 'window' && $ip)
	{ make_http_header(); print encode_string(EDIT_SUCCESSFUL->(stylesheets=>get_stylesheets(),board=>$board));  }
	else # $caller eq 'board' or anything else
	{ make_http_forward($board->path.'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT); }
}

sub delete_post($$$$)
{
	my ($post,$password,$fileonly,$archiving)=@_;
	my ($sth,$row,$res,$reply);
	my $thumb=$board->option('THUMB_DIR');
	my $archive=$board->option('ARCHIVE_DIR');
	my $src=$board->option('IMG_DIR');
	my $postinfo;

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=?;") or make_error(S_SQLFAIL);
	$sth->execute($post) or make_error(S_SQLFAIL);

	if($row=$sth->fetchrow_hashref())
	{
		make_error(S_BADDELPASS) if($password and $$row{password} ne $password);
		make_error("This was posted by a moderator or admin and cannot be deleted this way.") if ($password and $$row{admin_post} eq 'yes');

		unless($fileonly)
		{
			# remove files from comment and possible replies
			$sth=$dbh->prepare("SELECT image,thumbnail FROM ".$board->option('SQL_TABLE')." WHERE num=? OR parent=?") or make_error(S_SQLFAIL);
			$sth->execute($post,$post) or make_error(S_SQLFAIL);

			while($res=$sth->fetchrow_hashref())
			{
				system($board->path.'/'.$board->option('LOAD_SENDER_SCRIPT')." $$res{image} &") if($board->option('ENABLE_LOAD'));
	
				if($archiving)
				{
					# archive images
					rename $board->path.'/'.$$res{image}, $board->path.'/'.$board->option('ARCHIVE_DIR').$$res{image};
					rename $board->path.'/'.$$res{thumbnail}, $board->path.'/'.$board->option('ARCHIVE_DIR').$$res{thumbnail} if($$res{thumbnail}=~/^$thumb/);
				}
				else
				{
					# delete images if they exist
					unlink $board->path.'/'.$$res{image};
					unlink $board->path.'/'.$$res{thumbnail} if($$res{thumbnail}=~/^$thumb/);
				}
			}

			# remove post and possible replies
			$sth=$dbh->prepare("DELETE FROM ".$board->option('SQL_TABLE')." WHERE num=? OR parent=?;") or make_error(S_SQLFAIL);
			$sth->execute($post,$post) or make_error(S_SQLFAIL);
		}
		else # remove just the image and update the database
		{
			if($$row{image})
			{
				system($board->path.'/'.$board->option('LOAD_SENDER_SCRIPT')." $$row{image} &") if($board->option('ENABLE_LOAD'));

				# remove images
				unlink $board->path.'/'.$$row{image};
				unlink $board->path.'/'.$$row{thumbnail} if($$row{thumbnail}=~/^$thumb/);

				$sth=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET size=0,md5=null,thumbnail=null WHERE num=?;") or make_error(S_SQLFAIL);
				$sth->execute($post) or make_error(S_SQLFAIL);
			}
		}

		# fix up the thread cache
		if(!$$row{parent})
		{
			unless($fileonly) # removing an entire thread
			{
				if($archiving)
				{
					my $captcha = $board->option('CAPTCHA_SCRIPT');
					my $line;

					open RESIN, '<', $board->path.'/'.$board->option('RES_DIR').$$row{num}.PAGE_EXT;
					open RESOUT, '>', $board->path.'/'.$board->option('ARCHIVE_DIR').$board->option('RES_DIR').$$row{num}.PAGE_EXT;
					while($line = <RESIN>)
					{
						$line =~ s/img src="(.*?)$thumb/img src="$1$archive$thumb/g;
						if($board->option('ENABLE_LOAD'))
						{
							my $redir = $board->path.'/'.$board->option('REDIR_DIR');
							$line =~ s/href="(.*?)$redir(.*?).html/href="$1$archive$src$2/g;
						}
						else
						{
							$line =~ s/href="(.*?)$src/href="$1$archive$src/g;
						}
						$line =~ s/src="[^"]*$captcha[^"]*"/src=""/g if($board->option('ENABLE_CAPTCHA'));
						print RESOUT $line;	
					}
					close RESIN;
					close RESOUT;
				}
				unlink $board->path.'/'.$board->option('RES_DIR').$$row{num}.PAGE_EXT;
			}
			else # removing parent image
			{
				build_thread_cache($$row{num});
			}
		}
		else # removing a reply, or a reply's image
		{
			build_thread_cache($$row{parent});
		}
		$postinfo = dec_to_dot($$row{ip});
	}
	
	$sth->finish();
	
	return $postinfo;
}

#
# Admin interface
#

sub make_admin_login(;$)
{
	my ($login_task) = @_;
	make_http_header();
	print encode_string(ADMIN_LOGIN_TEMPLATE->(login_task=>$login_task,stylesheets=>get_stylesheets(),board=>$board));
}

sub make_admin_post_panel($$)
{
	my ($admin, $page)=@_;
	my ($sth,$row,@threads);

	my ($username, $type) = check_password($admin, 'mpanel');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	# Grab reported posts
	my @reportedposts = local_reported_posts();

	# Grab board posts
	if ($page =~ /^t\w+$/)
	{
		$page =~ s/^t//g;
		$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num=? OR parent=? ORDER BY lasthit DESC, num ASC;") or make_error(S_SQLFAIL);
		$sth->execute($page,$page) or make_error(S_SQLFAIL);
		
		$row = get_decoded_hashref($sth);
		make_error("Thread does not exist") if !$row;
		my @thread;
		push @thread, $row;
		while ($row=get_decoded_hashref($sth))
		{
			push @thread, $row;
		}
		push @threads,{posts=>[@thread]};
		
		make_http_header();
		print encode_string(POST_PANEL_TEMPLATE->(
			admin=>$admin,
			board=>$board,
			postform=>($board->option('ALLOW_TEXTONLY') or $board->option('ALLOW_IMAGES')),
			image_inp=>$board->option('ALLOW_IMAGES'),
			textonly_inp=>0,
			threads=>\@threads,
			username=>$username,
			thread=>$page,
			reportedposts=>\@reportedposts,
			lockedthread=>$thread[0]{locked},
			type=>$type,
			parent=>$page,
			stylesheets=>get_stylesheets()));
	}
	else
	{
		# Grab count of threads
		my $threadcount = count_threads();
		
		# Handle page variable
		my $last_page = int(($threadcount + $board->option('IMAGES_PER_PAGE') - 1) / $board->option('IMAGES_PER_PAGE'))-1; 
		$page = $last_page if (($page) * $board->option('IMAGES_PER_PAGE') + 1 > $count);
		$page = 0 if ($page !~ /^\w+$/);
		my $thread_offset = $page * ($board->option('IMAGES_PER_PAGE'));
		
		# Grab the parent posts
		$sth=$dbh->prepare("SELECT ".$board->option('SQL_TABLE').".* FROM ".$board->option('SQL_TABLE')." WHERE parent=0 ORDER BY stickied DESC, lasthit DESC, ".$board->option('SQL_TABLE').".num ASC LIMIT ".$board->option('IMAGES_PER_PAGE')." OFFSET $thread_offset;") or make_error(S_SQLFAIL);
		$sth->execute() or make_error(S_SQLFAIL);
		
		# Grab the thread posts in each thread
		while ($row=get_decoded_hashref($sth))
		{                                  
			my @thread = ($row);
			my $threadnumber = $$row{num};
			
			# Grab thread replies
			my $postcountquery=$dbh->prepare("SELECT COUNT(*) AS count, COUNT(image) AS imgcount FROM ".$board->option('SQL_TABLE')." WHERE parent=?") or make_error(S_SQLFAIL);
			$postcountquery->execute($threadnumber) or make_error(S_SQLFAIL);
			my $postcountrow = $postcountquery->fetchrow_hashref();
			my $postcount = $$postcountrow{count};
			my $imgcount = $$postcountrow{imgcount};
			$postcountquery->finish();
			
			# Grab limits for SQL query
			my $offset = ($postcount > $board->option('REPLIES_PER_THREAD')) ? $postcount - ($board->option('IMAGES_PER_PAGE')) : 0;
			my $limit = $board->option('REPLIES_PER_THREAD');
			my $shownimages = 0;
			
			my $threadquery=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE parent=? ORDER BY stickied DESC, lasthit DESC, ".$board->option('SQL_TABLE').".num ASC LIMIT $limit OFFSET $offset;") or make_error(S_SQLFAIL);
			$threadquery->execute($threadnumber) or make_error(S_SQLFAIL);
			while (my $inner_row=get_decoded_hashref($threadquery))
			{
				push @thread, $inner_row;
				$shownimages++ if $$inner_row{image};
			}
			$threadquery->finish();
	
			push @threads,{posts=>[@thread],omit=>($postcount > $limit) ? $postcount-$limit : 0,omitimages=>($imgcount > $shownimages) ? $imgcount-$shownimages : 0};
		}
		
		$sth->finish();
		
		# make the list of pages
		my @pages=map +{ page=>$_ },(0..$last_page);
		foreach my $p (@pages)
		{
			if($$p{page}==0) { $$p{filename}=get_secure_script_name().'?task=mpanel&amp;board='.$board->path() } # first page
			else { $$p{filename}=get_secure_script_name().'?task=mpanel&amp;board='.$board->path().'&amp;page='.$$p{page} }
			if($$p{page}==$page) { $$p{current}=1 } # current page, no link
		}
		
		my ($prevpage,$nextpage) = ('none','none');
		$prevpage=$page-1 if($page!=0);
		$nextpage=$page+1 if($page!=$last_page);
	
		make_http_header();
		print encode_string(POST_PANEL_TEMPLATE->(
			admin=>$admin,
			board=>$board,
			postform=>($board->option('ALLOW_TEXTONLY') or $board->option('ALLOW_IMAGES')),
			image_inp=>$board->option('ALLOW_IMAGES'),
			textonly_inp=>($board->option('ALLOW_IMAGES') and $board->option('ALLOW_TEXTONLY')),
			nextpage=>$nextpage,
			prevpage=>$prevpage,
			threads=>\@threads,
			username=>$username,
			reportedposts=>\@reportedposts,
			type=>$type,
			pages=>\@pages,
			stylesheets=>get_stylesheets()));
	}
}

sub make_admin_ban_panel($$)
{
	my ($admin, $ip)=@_;
	my ($sth,$row,@bans,$prevtype);

	my ($username, $type) = check_password($admin, 'bans');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	$sth=$dbh->prepare("SELECT ".SQL_ADMIN_TABLE.".*, ".SQL_STAFFLOG_TABLE.".username FROM ".SQL_ADMIN_TABLE." LEFT OUTER JOIN ".SQL_STAFFLOG_TABLE." ON ".SQL_ADMIN_TABLE.".num=".SQL_STAFFLOG_TABLE.".admin_id AND ".SQL_ADMIN_TABLE.".type=".SQL_STAFFLOG_TABLE.".action WHERE type='ipban' OR type='wordban' OR type='whitelist' OR type='trust' ORDER BY type ASC,num ASC;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	while($row=get_decoded_hashref($sth))
	{
		$$row{divider}=1 if($prevtype ne $$row{type});
		$prevtype=$$row{type};
		$$row{rowtype}=@bans%2+1;
		$$row{expirehuman}=($$row{expiration}) ? epoch_to_human($$row{expiration}) : 'Never';
		$$row{browsingban}=($$row{total} eq 'yes') ? 'No' : 'Yes';
		push @bans,$row;
	}
	
	$sth->finish();

	make_http_header();
	print encode_string(BAN_PANEL_TEMPLATE->(admin=>$admin,bans=>\@bans,ip=>$ip,username=>$username,type=>$type, stylesheets=>get_stylesheets(),board=>$board));
}

sub add_ip_ban_window($$@) # Generate ban popup window
{
	my ($admin,$delete,$ip) = @_;
	my ($username, $type) = check_password($admin, 'bans');

	make_http_header();
	print encode_string(BAN_WINDOW->(admin=>$admin,stylesheets=>get_stylesheets(),ip=>$ip,board=>$board,'delete'=>$delete));
}

sub confirm_ip_ban($$$$$$$@)
{
	my ($admin,$comment,$mask,$total,$expiration,$delete,$delete_all,@ip) = @_;
	my ($username, $type) = check_password($admin, 'bans');
	
	foreach my $ip_address (@ip) # Ban each IP address
	{
		add_admin_entry($admin,'ipban',$comment,$ip_address,$mask,'',$total,$expiration,'internal');
		if ($delete_all) # If the moderator elected to delete all posts from IP, do so
		{
			delete_all($admin,$ip_address,$mask,'internal');
		}
	}
	
	if ($delete) # If there is only one post selected for baleetion, nuke it.
	{
		delete_stuff('',0,'',$admin,1,'internal',($delete));
	}
	
	# redirect to confirmation page
	make_http_header();
	print encode_string(EDIT_SUCCESSFUL->(stylesheets=>get_stylesheets(),board=>$board)); 
}

sub add_thread_ban_window($$)
{
	my ($admin,$num) = @_;
	my ($username, $type) = check_password($admin, 'bans');
	
	make_http_header();
	print encode_string(BAN_THREAD_TEMPLATE->(admin=>$admin,num=>$num,username=>$username,type=>$type, stylesheets=>get_stylesheets(),board=>$board));
}

sub ban_thread($$$$$$)
{
	my ($admin,$num,$comment,$expiration,$total,$delete) = @_;
	my ($username, $type) = check_password($admin, 'bans');
	my (%posts);
	
	my $sth=$dbh->prepare("SELECT parent FROM ".$board->option('SQL_TABLE')." WHERE num=? LIMIT 1;") or make_error(S_SQLFAIL,1);
	$sth->execute($num) or make_error(S_SQLFAIL,1);
	my $row=$sth->fetchrow_hashref();
	$sth->finish();
	
	if (!$$row{parent})
	{
		my $ban_list = $dbh->prepare("SELECT ip FROM ".$board->option('SQL_TABLE')." WHERE parent=? OR num=? LIMIT 1;") or make_error(S_SQLFAIL);
		$ban_list->execute($num,$num);
		while (my $banned_ip=($ban_list->fetchrow_array())[0])
		{
			add_admin_entry($admin,'ipban',$comment,$banned_ip,'','',$total,$expiration,'internal') if (!(exists $posts{$banned_ip}));
			$posts{$banned_ip}++;
		}
		delete_stuff('',0,'',$admin,1,'internal',($num));
	}
	else
	{
		make_error(S_NOTATHREAD,1);
	}
	
	make_http_header();
	print encode_string(EDIT_SUCCESSFUL->(stylesheets=>get_stylesheets()));
}

sub make_admin_ban_edit($$) # generating ban editing window
{
	my ($admin, $num) = @_;

	my ($username, $type) = check_password($admin, 'bans');

	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));
	
	my (@hash, $time);
	my $sth = $dbh->prepare("SELECT * FROM ".SQL_ADMIN_TABLE." WHERE num=?") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	my @utctime;
	while (my $row=get_decoded_hashref($sth))
	{
		push (@hash, $row);
		if ($$row{expiration} != 0)
		{
			@utctime = gmtime($$row{expiration}); #($sec, $min, $hour, $day,$month,$year)
		} 
		else
		{
			@utctime = gmtime(time);
		}
	}
	make_http_header();
	print encode_string(EDIT_WINDOW->(admin=>$admin, hash=>\@hash, sec=>$utctime[0], min=>$utctime[1], hour=>$utctime[2], day=>$utctime[3], month=>$utctime[4]++, year=>$utctime[5] + 1900, stylesheets=>get_stylesheets(),board=>$board));
}


sub make_admin_proxy_panel($)
{
	my ($admin)=@_;
	my ($sth,$row,@scanned,$prevtype);

	my ($username, $type) = check_password($admin, 'proxy');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	proxy_clean();

	$sth=$dbh->prepare("SELECT * FROM ".SQL_PROXY_TABLE." ORDER BY timestamp ASC;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	while($row=get_decoded_hashref($sth))
	{
		$$row{divider}=1 if($prevtype ne $$row{type});
		$prevtype=$$row{type};
		$$row{rowtype}=@scanned%2+1;
		push @scanned,$row;
	}
	
	$sth->finish();

	make_http_header();
	print encode_string(PROXY_PANEL_TEMPLATE->(admin=>$admin,scanned=>\@scanned,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board));
}

sub make_admin_spam_panel($)
{
	my ($admin)=@_;
	my @spam_files=SPAM_FILES;
	my @spam=read_array($spam_files[0]);

	my ($username, $type) = check_password($admin, 'spam');
	make_error("Insufficient Privledges") if ($type eq "mod");
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	make_http_header();
	print encode_string(SPAM_PANEL_TEMPLATE->(admin=>$admin,
	stylesheets=>get_stylesheets(),
	board=>$board,
	spamlines=>scalar @spam,
	username=>$username, type=>$type,
	spam=>join "\n",map { clean_string($_,1) } @spam, ));
}

sub make_sql_dump($)
{
	my ($admin)=@_;
	my ($sth,$row,@database);

	my ($username, $type) = check_password($admin, 'sqldump');
	make_error("Insufficient privledges.") if ($type ne 'admin');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE').";") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	while($row=get_decoded_arrayref($sth))
	{
		push @database,"INSERT INTO ".$board->option('SQL_TABLE')." VALUES('".
		(join "','",map { s/\\/&#92;/g; $_ } @{$row}). # escape ' and \, and join up all values with commas and apostrophes
		"');";
	}

	$sth->finish();

	make_http_header();
	print encode_string(
		SQL_DUMP_TEMPLATE->(admin=>$admin,
		username=>$username,
		type=>$type,
		stylesheets=>get_stylesheets(),
		board=>$board,
		database=>join "<br />",map { clean_string($_,1) } @database
	));
}

sub make_sql_interface($$$)
{
	my ($admin,$nuke,$sql)=@_;
	my ($sth,$row,@results);

	my ($username, $type) = check_password($admin, 'sql');
	make_error("Insufficient privledges.") if $type ne 'admin';
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	if($sql)
	{
		make_error(S_WRONGPASS) if($nuke ne $board->option('NUKE_PASS')); # check nuke password

		my @statements=grep { /^\S/ } split /\r?\n/,decode_string($sql,CHARSET,1);

		foreach my $statement (@statements)
		{
			push @results,">>> $statement";
			if($sth=$dbh->prepare($statement))
			{
				if($sth->execute())
				{
					while($row=get_decoded_arrayref($sth)) { push @results,join ' | ',@{$row} }
					$sth->finish();
				}
				else { push @results,"!!! ".$sth->errstr(); $sth->finish(); }
			}
			else { push @results,"!!! ".$sth->errstr(); $sth->finish(); }
		}
	}

	make_http_header();
	print encode_string(SQL_INTERFACE_TEMPLATE->(
		admin=>$admin,
		username=>$username,
		type=>$type,
		nuke=>$nuke,
		stylesheets=>get_stylesheets(),
		board=>$board,
		results=>join "<br />",map { clean_string($_,1) } @results
	));
}

sub make_admin_post($)
{
	my ($admin)=@_;

	my ($username, $type) = check_password($admin, 'mpost');
	
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	make_http_header();
	print encode_string(ADMIN_POST_TEMPLATE->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board));
}

sub make_staff_activity_panel($$$$$$$$$$)
{
	my ($admin,$view,$user_to_view,$action_to_view,$ip_to_view,$post_to_view,$sortby,$order,$page,$perpage) = @_;
	my ($username, $type) = check_password($admin, 'stafflog');
	my (@entries,@staff,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page);
	
	make_error("Insufficient pivledges") if $type ne 'admin';
	
	# Pagination
	
	$perpage = 50 if (!$perpage || $perpage !~ /^\d+$/);
	$page = 1 if (!$page || $page !~ /^\d+$/);
	
	# SQL ORDER BY String

	my $sortby_string = 'ORDER BY ';
	if ($sortby eq 'username' || $sortby eq 'account' || $sortby eq 'action' || $sortby eq 'date')
	{
		$sortby_string .= $sortby . ' ' . (($order =~ /^asc/i) ? 'ASC' : 'DESC') . (($sortby ne 'date') ? ', date DESC' : '');
	}
	else
	{
		$sortby_string .= 'date DESC';
	}
	
	# Grab Staff Info
	
	my $staff_get = $dbh->prepare("SELECT username FROM ".SQL_ACCOUNT_TABLE.";");
	$staff_get->execute();
	while (my $staff_row = get_decoded_hashref($staff_get))
	{
		push @staff, $staff_row;
	}
	$staff_get->finish();
	
	# Handle Current Page View

	if ($view eq 'user')
	{
		make_error("Please select a user to view.") if (!$user_to_view);
		
		my $count_get = $dbh->prepare("SELECT COUNT(*) FROM ".SQL_STAFFLOG_TABLE." WHERE username=?;");
		$count_get->execute($user_to_view) or make_error(S_SQLFAIL);
		my $count = ($count_get->fetchrow_array())[0];
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
		$count_get->finish();
		
		my $sth=$dbh->prepare("SELECT * FROM ".SQL_STAFFLOG_TABLE." WHERE username=? $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
		$sth->execute($user_to_view) or make_error(S_SQLFAIL);
	
		my $rowtype = 1;
		while (my $row = get_decoded_hashref($sth))
		{
			$rowtype ^= 3;
			$$row{rowtype}=$rowtype;
	
			push @entries,$row;
		}

		$sth->finish();
		
		my @page_setting_hidden_inputs = ({name=>'usertoview',value=>$user_to_view},{name=>'board',value=>$board->path()},{name=>'task',value=>'stafflog'},{name=>'view',value=>$view},{name=>'posttoview',value=>$post_to_view},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby});
		
		make_http_header();
		print encode_string(STAFF_ACTIVITY_BY_USER->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,user_to_view=>$user_to_view,rowcount=>$count,perpage=>$perpage,page=>$page,number_of_pages=>$number_of_pages,view=>$view,sortby=>$sortby,staff=>\@staff,order=>$order,rooturl=>get_secure_script_name()."?task=stafflog&amp;board=".$board->path()."&amp;view=$view&amp;sortby=$sortby&amp;order=$order&amp;usertoview=$user_to_view",entries=>\@entries,inputs=>\@page_setting_hidden_inputs));
	}
	elsif ($view eq 'action')
	{
		# Handle the Name of the Page (content_name) and of the Column (action_name)
		
		my ($action_name, $action_content) = get_action_name($action_to_view,1);

		my $count_get = $dbh->prepare("SELECT COUNT(*) FROM ".SQL_STAFFLOG_TABLE." WHERE action=?;");
		$count_get->execute($action_to_view) or make_error(S_SQLFAIL);
		my $count = ($count_get->fetchrow_array())[0];
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	
		$count_get->finish();
		
		my $sth = $dbh->prepare("SELECT ".SQL_ACCOUNT_TABLE.".username,".SQL_ACCOUNT_TABLE.".account,".SQL_ACCOUNT_TABLE.".disabled,".SQL_STAFFLOG_TABLE.".info,".SQL_STAFFLOG_TABLE.".date,".SQL_STAFFLOG_TABLE.".ip FROM ".SQL_STAFFLOG_TABLE." LEFT JOIN ".SQL_ACCOUNT_TABLE." ON ".SQL_STAFFLOG_TABLE.".username=".SQL_ACCOUNT_TABLE.".username WHERE ".SQL_STAFFLOG_TABLE.".action=? $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
		$sth->execute($action_to_view) or make_error(S_SQLFAIL);

		my $rowtype=1;
		while(my $row=get_decoded_hashref($sth))
		{
			$rowtype^=3;
			$$row{rowtype}=$rowtype;

			push @entries,$row;
		}
		
		$sth->finish();
		
		my @page_setting_hidden_inputs = ({name=>'actiontoview',value=>$action_to_view},{name=>'board',value=>$board->path()},{name=>'task',value=>'stafflog'},{name=>'view',value=>$view},{name=>'posttoview',value=>$post_to_view},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby}); 

		make_http_header();
		print encode_string(STAFF_ACTIVITY_BY_ACTIONS->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,action=>$action_to_view,action_name=>$action_name,content_name=>$action_content,page=>$page,perpage=>$perpage,number_of_pages=>$number_of_pages,rowcount=>$count,view=>$view,sortby=>$sortby,staff=>\@staff,order=>$order,rooturl=>get_secure_script_name()."?task=stafflog&amp;board=".$board->path()."&amp;view=$view&amp;sortby=$sortby&amp;order=$order&amp;actiontoview=$action_to_view",entries=>\@entries,inputs=>\@page_setting_hidden_inputs));
	}
	elsif ($view eq 'ip')
	{
		make_error("Invalid IP Address.") if $ip_to_view !~ /^\d+\.\d+\.\d+\.\d+$/;
		
		my $count_get = $dbh->prepare("SELECT COUNT(*) FROM ".SQL_STAFFLOG_TABLE." WHERE info LIKE ?;");
		$count_get->execute('%'.$ip_to_view.'%') or make_error(S_SQLFAIL);
		my $count = ($count_get->fetchrow_array())[0];
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	
		$count_get->finish();
		
		my $sth = $dbh->prepare("SELECT ".SQL_ACCOUNT_TABLE.".username,".SQL_ACCOUNT_TABLE.".account,".SQL_ACCOUNT_TABLE.".disabled,".SQL_STAFFLOG_TABLE.".action,".SQL_STAFFLOG_TABLE.".info,".SQL_STAFFLOG_TABLE.".date,".SQL_STAFFLOG_TABLE.".ip FROM ".SQL_STAFFLOG_TABLE." LEFT JOIN ".SQL_ACCOUNT_TABLE." ON ".SQL_STAFFLOG_TABLE.".username=".SQL_ACCOUNT_TABLE.".username WHERE info LIKE ? $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
		$sth->execute('%'.$ip_to_view.'%') or make_error(S_SQLFAIL);
	
		my $rowtype = 1;
		while (my $row=get_decoded_hashref($sth))
		{
			$rowtype ^= 3;
			$$row{rowtype}=$rowtype;
	
			push @entries,$row;
		}
		
		$sth->finish();
		
		my @page_setting_hidden_inputs = ({name=>'board',value=>$board->path()},{name=>'task',value=>'stafflog'},{name=>'view',value=>$view},{name=>'iptoview',value=>$ip_to_view},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby}); 
		
		make_http_header();
		print encode_string(STAFF_ACTIVITY_BY_IP_ADDRESS->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,ip_to_view=>$ip_to_view,rowcount=>$count,page=>$page,perpage=>$perpage,number_of_pages=>$number_of_pages,view=>$view,sortby=>$sortby,staff=>\@staff,order=>$order,rooturl=>get_secure_script_name()."?task=stafflog&amp;board=".$board->path()."&amp;view=$view&amp;sortby=$sortby&amp;order=$order&amp;iptoview=$ip_to_view",entries=>\@entries,inputs=>\@page_setting_hidden_inputs));
	}
	elsif ($view eq 'post')
	{
		$post_to_view = $board->path().','.$post_to_view if $post_to_view !~ /,/;
		
		my $count_get = $dbh->prepare("SELECT COUNT(*) FROM ".SQL_STAFFLOG_TABLE." WHERE info LIKE ?;");
		$count_get->execute('%'.$post_to_view.'%') or make_error(S_SQLFAIL);
		my $count = ($count_get->fetchrow_array())[0];
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	
		$count_get->finish();
		
		my $sth = $dbh->prepare("SELECT ".SQL_ACCOUNT_TABLE.".username,".SQL_ACCOUNT_TABLE.".account,".SQL_ACCOUNT_TABLE.".disabled,".SQL_STAFFLOG_TABLE.".action,".SQL_STAFFLOG_TABLE.".info,".SQL_STAFFLOG_TABLE.".date,".SQL_STAFFLOG_TABLE.".ip FROM ".SQL_STAFFLOG_TABLE." LEFT JOIN ".SQL_ACCOUNT_TABLE." ON ".SQL_STAFFLOG_TABLE.".username=".SQL_ACCOUNT_TABLE.".username WHERE info LIKE ? $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
		$sth->execute('%'.$post_to_view.'%') or make_error(S_SQLFAIL);
	
		my $rowtype = 1;
		while (my $row=get_decoded_hashref($sth))
		{
			$rowtype ^= 3;
			$$row{rowtype}=$rowtype;

			push @entries,$row;
		}
		
		$sth->finish();
		
		my @page_setting_hidden_inputs = ({name=>'board',value=>$board->path()},{name=>'task',value=>'stafflog'},{name=>'view',value=>$view},{name=>'posttoview',value=>$post_to_view},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby}); 
		
		make_http_header();
		print encode_string(STAFF_ACTIVITY_BY_POST->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,post_to_view=>$post_to_view,rowcount=>$count,page=>$page,perpage=>$perpage,number_of_pages=>$number_of_pages,view=>$view,staff=>\@staff,sortby=>$sortby,order=>$order,rooturl=>get_secure_script_name()."?task=stafflog&amp;board=".$board->path()."&amp;view=$view&amp;sortby=$sortby&amp;order=$order&amp;posttoview=$post_to_view",entries=>\@entries,inputs=>\@page_setting_hidden_inputs));
	}
	else
	{
		my $count_get = $dbh->prepare("SELECT COUNT(*) FROM ".SQL_STAFFLOG_TABLE.";");
		$count_get->execute or make_error(S_SQLFAIL);
		my $count = ($count_get->fetchrow_array())[0];
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	
		$count_get->finish();
		
		my $sth = $dbh->prepare("SELECT ".SQL_ACCOUNT_TABLE.".username,".SQL_ACCOUNT_TABLE.".account,".SQL_ACCOUNT_TABLE.".disabled,".SQL_STAFFLOG_TABLE.".action,".SQL_STAFFLOG_TABLE.".info,".SQL_STAFFLOG_TABLE.".date,".SQL_STAFFLOG_TABLE.".ip FROM ".SQL_STAFFLOG_TABLE." LEFT JOIN ".SQL_ACCOUNT_TABLE." ON ".SQL_STAFFLOG_TABLE.".username=".SQL_ACCOUNT_TABLE.".username $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
		$sth->execute() or make_error(S_SQLFAIL);
	
		my $rowtype = 1;
		my $entry_number = 0; # Keep track of this for pagination
		while (my $row=get_decoded_hashref($sth))
		{
			$entry_number++;
			$rowtype ^= 3;
			$$row{rowtype}=$rowtype;
	
			push @entries,$row;
		}
		
		$sth->finish();
		
		my @page_setting_hidden_inputs = ({name=>'board',value=>$board->path()},{name=>'task',value=>'stafflog'},{name=>'view',value=>$view},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby}); 
		
		make_http_header();
		print encode_string(STAFF_ACTIVITY_UNFILTERED->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,action=>$action_to_view,rowcount=>$count,page=>$page,perpage=>$perpage,number_of_pages=>$number_of_pages,view=>$view,sortby=>$sortby,staff=>\@staff,order=>$order,rooturl=>get_secure_script_name()."?task=stafflog&amp;board=".$board->path()."&amp;sortby=$sortby&amp;order=$order",entries=>\@entries,inputs=>\@page_setting_hidden_inputs));
	}
}

sub show_staff_edit_history($$)
{
	my ($admin,$num) = @_;
	my ($username,$type) = check_password($admin, '', 1);
	my @edits;
	
	my $sth = $dbh->prepare("SELECT ".SQL_STAFFLOG_TABLE.".username,".SQL_STAFFLOG_TABLE.".date FROM ".SQL_STAFFLOG_TABLE." INNER JOIN ".$board->option('SQL_TABLE')." ON ".SQL_STAFFLOG_TABLE.".info=CONCAT('".$board->option('SQL_TABLE').",',".$board->option('SQL_TABLE').".num) WHERE ".$board->option('SQL_TABLE').".num=? AND ".SQL_STAFFLOG_TABLE.".action='admin_edit' ORDER BY ".SQL_STAFFLOG_TABLE.".date DESC;") or make_error(S_SQLFAIL);
	$sth->execute($num);
	
	while(my $row=$sth->fetchrow_hashref())
	{
		push @edits,$row;
	}
	
	make_http_header();
	print encode_string(STAFF_EDIT_HISTORY->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,num=>$num,edits=>\@edits));
}

sub get_action_name($;$)
{
	my ($action_to_view,$debug)=@_;
	my %action =				# List of names and column names for each action type
	( ipban => { name => "IP Ban", content => "Affected IP Address" },
	  ipban_edit => { name => "IP Ban Revision", content => "Revised Data" },
	  ipban_remove => { name => "IP Ban Removal", content => "Unbanned IP Address" },
	  wordban => { name => "Word Ban", content => "Banned Phrase" },
	  wordban_edit => { name => "Word Ban Revision", content => "Revised Data" },
	  wordban_remove => { name => "Word Ban Removal", content => "Unbanned Phrase" },
	  whitelist => { name => "IP Whitelist", content => "Whitelisted IP Address" },
	  whitelist_edit => { name => "IP Whitelist Revision", content => "Revised Data" },
	  whitelist_remove => { name => "IP Whitelist Removal", content => "Removed IP Address" },
	  trust => { name => "Captcha Exemption", content => "Exempted Tripcode" },
	  trust_edit => { name => "Revised Captcha Exemption", content => "Revised Data" },
	  trust_remove => { name => "Removed Captcha Exemption", content => "Removed Tripcode" },
	  admin_post => { name => "Manager Post", content => "Post" },
	  admin_edit => { name => "Administrative Edit", content => "Post" },
	  admin_delete => { name => "Administrative Deletion", content => "Post" },
	  thread_sticky => { name => "Thread Sticky", content => "Thread Parent" },
	  thread_unsticky => { name => "Thread Unsticky", content=> "Thread Parent" },
	  thread_lock => { name => "Thread Lock", content => "Thread Parent" },
	  thread_unlock => { name => "Thread Unlock", content => "Thread Parent" },
	  report_resolve => { name => "Report Resolution", content => "Resolved Post" }
	);
	
	# If a search on an unknown action was requested, return an error.
	make_error("Please select an action to view.") if (!defined($action{$action_to_view}) && $debug == 1);
	
	my ($name, $content) = (defined($action{$action_to_view})) ?
				($action{$action_to_view}{name}, $action{$action_to_view}{content}) # Known action
				: ($action_to_view, "Content"); # Unknown action in log. (Shouldn't happen.)
	return ($name) if !$debug;
	return ($name, $content) if $debug == 1;
	return ($content) if $debug == 2;
}

sub get_reign($)
{
}

#
# Admin Post Searching
#

sub search_posts($$$$$$)
{
	my ($admin, $search_type, $query_string,$page,$perpage,$caller) = @_;
	my $popup = ($caller ne 'board') ? 1 : 0;
	my ($username, $type) = check_password($admin,'report',$popup);
	my ($sth,@posts,$count,$row,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page);
	
	if ($search_type eq 'ip')
	{
		make_error('Incorrect IP format',$popup) if ($query_string !~ /^\d+\.\d+\.\d+\.\d+$/);
		my $numip = dot_to_dec($query_string);
		
		# Construct counting query
		
		$sth=$dbh->prepare('SELECT COUNT(*) FROM '.$board->option('SQL_TABLE').' WHERE ip=? ORDER BY num DESC;') or make_error(S_SQLFAIL,$popup);
		$sth->execute($numip) or make_error(S_SQLFAIL,$popup);
		$count=($sth->fetchrow_array)[0];
		make_error("No posts found for specified IP address ($query_string).",$popup) if (!$count);
		$sth->finish();
		
		# Pagination

		$perpage = 10 if (!$perpage || $perpage !~ /^\d+$/);
		$page = 1 if (!$page || $page !~ /^\d+$/);
		
		($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
		
		my @page_setting_hidden_inputs = ({name=>'task', value=>'search'},{name=>'board',value=>$board->path()});
		
		# Construct content query
		
		$sth=$dbh->prepare('SELECT * FROM '.$board->option('SQL_TABLE')." WHERE ip=? ORDER BY num DESC LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL,$popup);
		$sth->execute($numip) or make_error(S_SQLFAIL,$popup);
		
		my $entry_number = $offset + 1;
		
		# Grab relevant posts
		
		while ($row = get_decoded_hashref($sth))
		{
			$$row{post_number}=$entry_number;
			push @posts, $row;
			$entry_number++;
		}
		
		$sth->finish();
	}
	else
	{
		make_error('Incorrect ID format',$popup) if ($query_string !~ /^\d+$/);
		
		# Construct query
		
		$sth=$dbh->prepare('SELECT * FROM '.$board->option('SQL_TABLE').' WHERE num=? LIMIT 1') or make_error(S_SQLFAIL,$popup);
		$sth->execute($query_string) or make_error(S_SQLFAIL,$popup);
		
		# Grab the single post we need.
		
		$row = get_decoded_hashref($sth);
		
		make_error("Post not found. (It may have just been deleted.)",$popup) if !$row;
		push @posts, $row;
		
		$sth->finish();
	}
	
	make_http_header();
	print encode_string(POST_SEARCH->(board=>$board,username=>$username,type=>$type,num=>$query_string,posts=>\@posts,search=>$search_type,stylesheets=>get_stylesheets(),rooturl=>get_secure_script_name().'?task=searchposts&amp;board='.$board->path().'&amp;caller='.$caller.'&amp;ipsearch=1&amp;ip='.$query_string,rowcount=>$count,perpage=>$perpage,page=>$page,number_of_pages=>$number_of_pages,popup=>$popup,admin=>$admin));
}

#
# Staff Login
#

sub do_login($$$$$)
{
	my ($username,$password,$nexttask,$savelogin,$admincookie)=@_;
	my $crypt;
	my @adminarray = split (/,/, $admincookie) if $admincookie;
	
	my $sth=$dbh->prepare("SELECT password,account,username FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute(($username || !$admincookie) ? $username : $adminarray[0]) or make_error(S_SQLFAIL);
	my $row=$sth->fetchrow_hashref();
	$sth->finish();
	
	if ($username && $username eq $$row{username}) # We must check the username field to ensure case-sensitivity
	{
		$crypt = $username.','.crypt_password($$row{password}) if ($row && hide_critical_data($password,SECRET) eq $$row{password} && !$$row{disabled});
		$nexttask||="mpanel";
	}
	elsif($admincookie && $adminarray[0] eq $$row{username})
	{
		$crypt=$admincookie if ($row && $adminarray[1] eq crypt_password($$row{password}));
		$nexttask||="mpanel";
	}
	
	if($crypt)
	{
		# Out with this old cookie
		make_cookies(wakaadminsave=>"",-expires=>1);
		
		# Cookie containing encrypted login info
		make_cookies(wakaadmin=>$crypt,
		-charset=>CHARSET,-autopath=>$board->option('COOKIE_PATH'),-expires=>(($savelogin) ? time+365*24*3600 : time+1800));
		
		# Cookie signaling to script that the cookie is being saved
		make_cookies(wakaadminsave=>1,
		-charset=>CHARSET,-autopath=>$board->option('COOKIE_PATH'),-expires=> time+365*24*3600) if $savelogin;
		
		make_http_forward(get_secure_script_name()."?task=$nexttask&board=".$board->path(),ALTERNATE_REDIRECT);
	}
	else { make_admin_login($nexttask); }
}

sub do_logout()
{
	make_cookies(wakaadmin=>"",-expires=>1);
	make_cookies(wakaadminsave=>"",-expires=>1);
	make_http_forward(get_secure_script_name()."?task=admin&board=".$board->path(),ALTERNATE_REDIRECT);
}

#
# Staff Verification
#

sub check_password($$;$)
{
	my ($admin,$task_redirect,$editing)=@_;
	
	my @adminarray = split (/,/, $admin); # <user>,rc6(<password+hostname>)
	
	my $sth=$dbh->prepare("SELECT password, username, account, disabled, reign FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($adminarray[0]) or make_error(S_SQLFAIL);

	my $row=$sth->fetchrow_hashref();
	
	# Access check
	my $path = $board->path(); # lol
	make_error("Sorry, you do not have access rights to this board.<br />(Accessible: ".$$row{reign}.")<br /><a href=\"".get_script_name()."?task=logout&amp;board=".$board->path()."\">Logout</a>") if ($$row{account} eq 'mod' && $$row{reign} !~ /\b$path\b/); 
	make_error("This account is disabled.") if ($$row{disabled});
	make_error(S_WRONGPASS,$editing) if ($$row{username} ne $adminarray[0] || !$adminarray[0]); # This is necessary, in fact, to ensure case-sensitivity for the username
	
	my $encrypted_pass = crypt_password($$row{password});
	$adminarray[1] =~ s/ /+/g; # Undoing encoding done in cookies. (+ is part of the base64 set)
	
	if ($adminarray[1] eq $encrypted_pass && !$$row{disabled}) # Return username,type if correct
	{
		make_cookies(wakaadmin=>$admin,
		-charset=>CHARSET,-autopath=>$board->option('COOKIE_PATH'),-expires=>time+1800) if (!($query->cookie('wakaadminsave')));
		
		my $account = $$row{account};
		$sth->finish();
		
		return ($adminarray[0],$account);
	}
	
	$sth->finish();
	
	$ENV{HTTP_REFERER} = get_secure_script_name().'?task=admin&amp;board='.$board->path()."&amp;nexttask=".$task_redirect; # Set up error page to direct back to login.
	make_error(S_WRONGPASS,$editing); # Otherwise, throw an error.
}

sub crypt_password($) 
{
	my $crypt=hide_critical_data((shift).$ENV{REMOTE_ADDR},SECRET); # Add in host address to curb cookie snatchers. Perhaps a MAC should be added in, too?
	#$crypt=~tr/+/./; # for web shit
	return $crypt;
}

#
# Management
#

sub do_rebuild_cache($;$)
{
	my ($admin,$do_not_redirect)=@_;

	check_password($admin, 'rebuild');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	unlink glob $board->path().'/'.$board->option('RES_DIR').'*'.PAGE_EXT;

	repair_database();
	build_thread_cache_all();
	build_cache();

	make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT) unless $do_not_redirect;
}

sub do_global_rebuild_cache($) # Rebuild all boards' caches
{
	my ($admin) = @_;
	my ($username,$type) = check_password($admin, 'mpanel');
	
	make_error("Insufficient Privledges") if ($type eq 'mod');
	
	my @boards = get_boards();
	
	my $current_board = $board->path(); # Store current board name for later retrieval.
	undef $board; # O LAWD WTF
	
	foreach my $board_hash (@boards)
	{
		$board = Board->new($$board_hash{board_entry}); # Aha! Build each individual board, as referenced in SQL_COMMON_SITE_TABLE
		if ($board->option('SQL_TABLE'))
		{
			do_rebuild_cache($admin,1);
		}
		undef $board;
	}
	
	$board = Board->new($current_board); # Return to the loop iteration's motherland
	
	make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
}

sub add_admin_entry($$$$$$$$$)
{
	my ($admin,$type,$comment,$ip,$mask,$sval1,$total,$expiration,$caller)=@_;
	
	my ($sth);
	
	my ($ival1,$ival2) = parse_range($ip,$mask);

	my ($username, $accounttype) = check_password($admin, 'bans');

	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));
	
	make_error(S_COMMENT_A_MUST) if !$comment;

	$comment=clean_string(decode_string($comment,CHARSET));
	
	$expiration = (!$expiration) ? 0 : time()+$expiration;
	
	make_error(S_STRINGFIELDMISSING) if ($type eq 'wordban' && $sval1 eq '');

	$sth=$dbh->prepare("INSERT INTO ".SQL_ADMIN_TABLE." VALUES(null,?,?,?,?,?,?,?);") or make_error(S_SQLFAIL);
	$sth->execute($type,$comment,$ival1,$ival2,$sval1,$total,$expiration) or make_error(S_SQLFAIL);
	
	if ($total eq 'yes' && $type eq 'ipban')
	{
		add_htaccess_entry(dec_to_dot($ival1));
	}
	
	$sth->finish();
	
	# Grab entry number
	my $select=$dbh->prepare("SELECT num FROM ".SQL_ADMIN_TABLE." WHERE type=? AND comment=? AND ival1=? AND ival2=? AND sval1=?;") or make_error(S_SQLFAIL);
	$select->execute($type,$comment,$ival1,$ival2,$sval1) or make_error(S_SQLFAIL);
	
	my $row = $select->fetchrow_hashref;
	
	# Add entry to staff log table
	add_log_entry($username,$type,(($type eq 'ipban' || $type eq 'whitelist') ? dec_to_dot($ival1).' / '.dec_to_dot($ival2) : $sval1),make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),$$row{num},time());
	
	$select->finish();
	
	make_http_forward(get_secure_script_name()."?task=bans&board=".$board->path(),ALTERNATE_REDIRECT) unless $caller eq 'internal';
}

sub edit_admin_entry($$$$$$$$$$$$$$$) # subroutine for editing entries in the admin table
{
	my ($admin,$num,$type,$comment,$ival1,$ival2,$sval1,$total,$sec,$min,$hour,$day,$month,$year,$noexpire)=@_;
	my ($sth, $not_total_before, $past_ip, $expiration, $changes);
	my ($username, $accounttype) = check_password($admin, 'bans');
	
	make_error(S_COMMENT_A_MUST) unless $comment;
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	# Sanity check
	my $verify=$dbh->prepare("SELECT * FROM ".SQL_ADMIN_TABLE." WHERE num=?") or make_error(S_SQLFAIL);
	$verify->execute($num) or make_error(S_SQLFAIL);
	my $row = get_decoded_hashref($verify);
	make_error("Entry has not created or was removed.") if !$row;
	make_error("Cannot change entry type.") if $type ne $$row{type};
	
	# Do we need to make changes to .htaccess?
	$not_total_before = 1 if ($$row{total} ne 'yes' && $type eq 'ipban');
	$past_ip = dec_to_dot($$row{ival1}) if ($type eq 'ipban');

	# New expiration Date	
	$expiration = (!$noexpire) ? (timegm($sec, $min, $hour, $day,$month-1,$year) || make_error(S_DATEPROBLEM)) : 0;
	
	# Assess changes made
	$changes .= "comment, " if ($comment ne $$row{comment});
	$changes .= "expiration date, " if ($expiration != $$row{expiration});
	$changes .= "IP address (original: ".dec_to_dot($$row{ival1}).", new: $ival1), " if ($ival1 ne dec_to_dot($$row{ival1}));
	$changes .= "string (original: ".$$row{sval1}.", new: $sval1), " if ($sval1 ne $$row{sval1});
	$changes .= "subnet mask (original: ".dec_to_dot($$row{ival2}).", new: $ival2), " if ($ival2 ne dec_to_dot($$row{ival2}));
	$changes = substr($changes, 0, -2);
	
	# Close old handler
	$verify->finish;

	if ($total eq 'yes' && ($not_total_before || $past_ip ne $ival1)) # If current IP or new IP is now on a browsing ban, add it to .htaccess.
	{
		add_htaccess_entry($ival1);
	}
	if (($total ne 'yes' || $past_ip ne $ival1) && !$not_total_before && $type eq 'ipban') # If the previous, different IP was banned from
	{															 # browsing, we should remove it from .htaccess now.
		remove_htaccess_entry($past_ip);
	}
	
	# Revise database entry
	$sth=$dbh->prepare("UPDATE ".SQL_ADMIN_TABLE." SET comment=?, ival1=?, ival2=?, sval1=?, total=?, expiration=? WHERE num=?")  
		or make_error(S_SQLFAIL);
	$sth->execute($comment, dot_to_dec($ival1), dot_to_dec($ival2), $sval1, $total, $expiration, $num) or make_error(S_SQLFAIL);
	$sth->finish;
	
	# Add log entry
	add_log_entry($username,$type."_edit",$changes,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),$num,time());
	
	make_http_header();
	print encode_string(EDIT_SUCCESSFUL->(stylesheets=>get_stylesheets(),board=>$board));
}

sub remove_admin_entry($$$$)
{
	my ($admin,$num,$override,$no_redirect)=@_;
	my ($username, $accounttype) = check_password($admin, 'bans');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR})) || $override;
	
	# Does the ban forbid browsing?
	my $totalverify_admin = $dbh->prepare("SELECT * FROM ".SQL_ADMIN_TABLE." WHERE num=?") or make_error(S_SQLFAIL);
	$totalverify_admin->execute($num) or make_error(S_SQLFAIL);
	while (my $row=get_decoded_hashref($totalverify_admin))
	{
		# Remove browsing ban if applicable
		if ($$row{total} eq 'yes')
		{
			my $ip = dec_to_dot($$row{ival1});
			remove_htaccess_entry($ip);
		}
		# Add log entry
		add_log_entry($username,$$row{type}."_remove",(($$row{type} eq 'ipban' || $$row{type} eq 'whitelist') ? dec_to_dot($$row{ival1}).' / '.dec_to_dot($$row{ival2}) : $$row{sval1}),make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),$num,time());
	}
	$totalverify_admin->finish();
	
	my $sth=$dbh->prepare("DELETE FROM ".SQL_ADMIN_TABLE." WHERE num=?;") or make_error(S_SQLFAIL);
	$sth->execute($num) or make_error(S_SQLFAIL);
	$sth->finish();

	make_http_forward(get_secure_script_name()."?task=bans&board=".$board->path(),ALTERNATE_REDIRECT) unless $no_redirect;
}

sub remove_ban_on_admin($)
{
	my ($admin) = @_;
	my $sth=$dbh->prepare("SELECT num FROM ".SQL_ADMIN_TABLE." WHERE ? & ival2 = ival1 & ival2") or make_error(S_SQLFAIL);
	$sth->execute(dot_to_dec($ENV{REMOTE_ADDR})) or make_error(S_SQLFAIL);
	my @rows_to_delete;
	while (my $row=get_decoded_hashref($sth))
	{
		push @rows_to_delete, $$row{num};
	}
	
	$sth->finish();
	
	for (my $i = 0; $i <= $#rows_to_delete; $i++)
	{
		remove_admin_entry($admin, $rows_to_delete[$i], 1, 1);
	}
}

sub delete_all($$$$)
{
	my ($admin,$unparsedip,$unparsedmask,$caller)=@_;
	my ($sth,$row,@posts);
	
	my ($ip, $mask) = parse_range($unparsedip,$unparsedmask);

	check_password($admin, 'mpanel');
	
	# Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));

	# Issue SQL query
	$sth=$dbh->prepare("SELECT num FROM ".$board->option('SQL_TABLE')." WHERE ip & ? = ? & ?;") or make_error(S_SQLFAIL);
	$sth->execute($mask,$ip,$mask) or make_error(S_SQLFAIL);
	while($row=$sth->fetchrow_hashref()) { push(@posts,$$row{num}); }
	$sth->finish();

	delete_stuff('',0,0,$admin,1,'internal',@posts);
	make_http_forward($ENV{HTTP_REFERER},ALTERNATE_REDIRECT) unless $caller eq 'internal';
}

sub update_spam_file($$)
{
	my ($admin,$spam)=@_;

	check_password($admin, 'spam');
	
	# ADDED - Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));
	# END ADDED

	my @spam=split /\r?\n/,$spam;
	my @spam_files=SPAM_FILES;
	write_array($spam_files[0],@spam);

	make_http_forward(get_secure_script_name()."?task=spam&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub do_nuke_database($$)
{
	my ($admin,$nuke)=@_;

	my ($username, $type) = check_password($admin, 'nuke');
	make_error("Insufficient Privledges") if ($type ne 'admin');
	make_error("Incorrect Nuke Password") if ($nuke ne $board->option('NUKE_PASS'));
	
	# ADDED - Is moderator banned?
	ban_admin_check(dot_to_dec($ENV{REMOTE_ADDR}), $admin) unless is_whitelisted(dot_to_dec($ENV{REMOTE_ADDR}));
	# END ADDED

	init_database();
	#init_admin_database();
	#init_proxy_database();

	# remove images, thumbnails and threads
	unlink glob $board->path().'/'.board->option('IMG_DIR').'*';
	unlink glob $board->path().'/'.board->option('THUMB_DIR').'*';
	unlink glob $board->path().'/'.board->option('RES_DIR').'*';
	
	build_cache();

	make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
}

#
# .htaccess Management
#

sub add_htaccess_entry($)
{
	my $ip = $_[0];
	$ip =~ s/\./\\\./g;
	my $ban_entries_found = 0;
	my $options_followsymlinks = 0;
	my $options_execcgi = 0;
	open (HTACCESSREAD, HTACCESS_PATH.".htaccess") 
	  or make_error(S_HTACCESSPROBLEM);
	while (<HTACCESSREAD>)
	{
		$ban_entries_found = 1 if m/RewriteEngine\s+On/i;
		$options_followsymlinks = 1 if m/Options.*?FollowSymLinks/i;
		$options_execcgi = 1 if m/Options.*?ExecCGI/i;
	}
	close HTACCESSREAD;
	open (HTACCESS, ">>".HTACCESS_PATH.".htaccess");
	print HTACCESS "\n".'Options +FollowSymLinks'."\n" if !$options_followsymlinks;
	print HTACCESS "\n".'Options +ExecCGI'."\n" if !$options_execcgi;
	print HTACCESS "\n".'RewriteEngine On'."\n" if !$ban_entries_found;
	print HTACCESS "\n".'# Ban added by Wakaba'."\n";
	print HTACCESS 'RewriteCond %{REMOTE_ADDR} ^'.$ip.'$'."\n";
	print HTACCESS 'RewriteRule !(\.pl|\.js$|\.css$|\.php$|sugg|ban_images) '.$ENV{SCRIPT_NAME}.'?task=banreport&board='.$board->path()."\n";
	# mod_rewrite entry. May need to be changed for different server software
	close HTACCESS;
}

sub remove_htaccess_entry($)
{
	my $ip = $_[0];
	$ip =~ s/\./\\\\\./g;
	open (HTACCESSREAD, HTACCESS_PATH.".htaccess") or warn "Error writing to .htaccess ";
	my $file_contents;
	while (<HTACCESSREAD>)
	{	
		$file_contents .= $_;
	}
	$file_contents =~ s/(.*)\n\r?\# Ban added by Wakaba.*?RewriteCond.*?$ip.*?RewriteRule\s+\!\(.*?\).*?\?task\=banreport\n(.*)/$1$2/s;
	close HTACCESSREAD;
	open (HTACCESSWRITE, ">".HTACCESS_PATH.".htaccess") or warn "Error writing to .htaccess ";
	print HTACCESSWRITE $file_contents;
	close HTACCESSWRITE;
}

#
# Staff Management and Logging
#

sub manage_staff($)
{
	my ($admin) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	my @users;
		
	make_error("Insufficient privledges.") if ($type ne 'admin'); 

	my $sth=$dbh->prepare("SELECT * FROM ".SQL_ACCOUNT_TABLE." ORDER BY account ASC,username ASC;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);

	my $rowtype=1;
	while(my $row=get_decoded_hashref($sth))
	{
		$rowtype^=3;
		$$row{rowtype}=$rowtype;
		
		# Grab the latest action for each user.
		my $latestaction = $dbh->prepare("SELECT action,date FROM ".SQL_STAFFLOG_TABLE." WHERE username=? ORDER BY date DESC LIMIT 1;") or make_error(S_SQLFAIL);
		$latestaction->execute($$row{username});
		
		my $actionrow=$latestaction->fetchrow_hashref();
		$$row{action} = $$actionrow{action};
		$$row{actiondate} = $$actionrow{date};
		
		$latestaction->finish();

		push @users,$row;
	}
	
	$sth->finish();
	
	my @boards = get_boards();

	make_http_header();
	print encode_string(STAFF_MANAGEMENT->(admin=>$admin, username=>$username, type=>$type, stylesheets=>get_stylesheets(), boards=>\@boards, board=>$board, users=>\@users));
}

sub make_remove_user_account_window($$)
{
	my ($admin,$user_to_delete)=@_;
	my ($username, $type) = check_password($admin, 'staff');
	
	make_error("Insufficient privledges.") if ($type ne 'admin');
	make_error("No username specified.") if (!$user_to_delete); 
	make_error("An Hero Mode not available.") if ($user_to_delete eq $username);

	my $sth=$dbh->prepare("SELECT account FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_delete) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	my $account = $$row{account};
	
	$sth->finish();
	
	make_http_header();
	print encode_string(STAFF_DELETE_TEMPLATE->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,account=>$account,user_to_delete=>$user_to_delete));
}

sub remove_user_account($$$)
{
	my ($admin,$user_to_delete,$admin_pass)=@_;
	my ($username, $type) = check_password($admin, 'staff');
	
	make_error("Insufficient privledges.") if ($type ne 'admin');
	make_error("No username specified.") if (!$user_to_delete); 
	make_error("An Hero Mode not available.") if ($user_to_delete eq $username);
	
	my $sth=$dbh->prepare("SELECT account FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_delete) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	
	make_error("Management password incorrect.") if ($$row{account} eq 'admin' && $admin_pass ne ADMIN_PASS);
	
	$sth->finish();
	
	my $deletion=$dbh->prepare("DELETE FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$deletion->execute($user_to_delete) or make_error(S_SQLFAIL);
	$deletion->finish();
	
	make_http_forward(get_secure_script_name()."?task=staff&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub make_disable_user_account_window($$)
{
	my ($admin,$user_to_disable)=@_;
	my ($username, $type) = check_password($admin, 'staff');
	
	make_error("Insufficient privledges.") if ($type ne 'admin');
	make_error("No username specified.") if (!$user_to_disable); 
	make_error("Give me back the razor, emo kid.") if ($user_to_disable eq $username);

	my $sth=$dbh->prepare("SELECT account,disabled FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_disable) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	
	my $account = $$row{account};
	
	$sth->finish();
	
	make_http_header();
	print encode_string(STAFF_DISABLE_TEMPLATE->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,account=>$account,user_to_disable=>$user_to_disable));
}

sub disable_user_account($$$)
{
	my ($admin,$user_to_disable,$admin_pass) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	
	# Sanity checks
	make_error("No username specified.") if (!$user_to_disable);
	make_error("Give me back the razor, emo kid.") if ($username eq $user_to_disable);
	make_error("Insufficient privledges.") if ($type ne 'admin');
	
	my $sth=$dbh->prepare("SELECT account FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_disable) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	
	make_error("Management password incorrect.") if ($$row{account} eq 'admin' && $admin_pass ne ADMIN_PASS);
	
	$sth->finish();
	
	my $disable=$dbh->prepare("UPDATE ".SQL_ACCOUNT_TABLE." SET disabled='1' WHERE username=?;") or make_error(S_SQLFAIL);
	$disable->execute($user_to_disable) or make_error(S_SQLFAIL);
	$disable->finish();
	
	make_http_forward(get_secure_script_name()."?task=staff&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub make_enable_user_account_window($$)
{
	my ($admin,$user_to_enable) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	
	my $sth=$dbh->prepare("SELECT account,disabled FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_enable) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	
	my $account = $$row{account};
	
	$sth->finish();
	
	make_http_header();
	print encode_string(STAFF_ENABLE_TEMPLATE->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,account=>$account,user_to_enable=>$user_to_enable));
}

sub enable_user_account($$$)
{
	my ($admin, $user_to_enable, $management_password) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	
	make_error("No username specified.") if (!$user_to_enable);
	make_error("Insufficient privledges.") if ($type ne 'admin');

	my $sth=$dbh->prepare("SELECT account FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_enable) or make_error(S_SQLFAIL);	
	
	my $row = $sth->fetchrow_hashref();
	
	make_error("Management password incorrect.") if ($$row{account} eq 'admin' && $management_password ne ADMIN_PASS);
	
	$sth->finish();
	
	my $disable=$dbh->prepare("UPDATE ".SQL_ACCOUNT_TABLE." SET disabled='0' WHERE username=?;") or make_error(S_SQLFAIL);
	$disable->execute($user_to_enable) or make_error(S_SQLFAIL);
	$disable->finish();
	
	make_http_forward(get_secure_script_name()."?task=staff&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub make_edit_user_account_window($$)
{
	my ($admin,$user_to_edit) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	my @users;
	
	make_error("Insufficient privledges.") if ($type ne 'admin' && $user_to_edit ne $username);
	
	my $sth=$dbh->prepare("SELECT account, reign FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_edit) or make_error(S_SQLFAIL);
	
	my $row = $sth->fetchrow_hashref();
	my $account = $$row{account};
	
	my @boards = get_boards();
	my @reign = sort (split (/ /, $$row{reign})); # Sort the list of boards so we can do quicker trickery with shift() 
	
	while (@reign)
	{
		my $board_under_power = shift (@reign);
		foreach my $row (@boards)
		{
			if ($$row{board} eq $board_under_power)
			{
				$$row{underpower} = 1; # Mark as ruled with an iron fist.
				last; 		       # ...And go to the next entry of reign (containing loop).
			}
		}
	}
	
	$sth->finish();
	
	make_http_header();
	print encode_string(STAFF_EDIT_TEMPLATE->(admin=>$admin,username=>$username,type=>$type,stylesheets=>get_stylesheets(),board=>$board,user_to_edit=>$user_to_edit,boards=>\@boards,account=>$account));
}

sub edit_user_account($$$$$$@)
{
	my ($admin,$management_password,$user_to_edit,$newpassword,$newclass,$originalpassword,@reign) = @_;
	my ($username, $type) = check_password($admin, 'staff');
	my $forcereign = 0;

	# Sanity check
	make_error("Insufficient privledges.") if ($user_to_edit ne $username && $type ne 'admin');
	make_error("No user specified.") if (!$user_to_edit);
	make_error("Please input only Latin letters, numbers, and underscores for the password.") if ($newpassword && $newpassword !~ /^[\w\d_]+$/);
	make_error("Please limit the password to thirty characters maximum.") if ($newpassword && length $newpassword > 30);
	make_error("Passwords should be at least eight characters!") if ($newpassword && length $newpassword < 8);

	my $sth=$dbh->prepare("SELECT * FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_edit) or make_error(S_SQLFAIL);

	my $row = $sth->fetchrow_hashref();

	make_error("Cannot alter your own account class.") if ($newclass && $user_to_edit eq $username && $newclass ne $$row{account});
	make_error("Cannot change your own reign.") if (@reign && join (" ", @reign) ne $$row{reign} && $user_to_edit eq $username);
	
	# Users can change their own password, but not others' if they are without administrative rights.
	make_error("Password incorrect.") if ($user_to_edit eq $username && hide_critical_data($originalpassword,SECRET) ne $$row{password});
	# Management password required for promoting an account to the Administrator class or editing an existing Administrator account.
	make_error("Management password incorrect.") if ((($$row{account} eq 'admin' && $user_to_edit ne $username) || ($newclass ne $$row{account} && $newclass eq 'admin')) && $management_password ne ADMIN_PASS);
	
	# Clear out unneeded changes
	$newclass = '' if ($newclass eq $$row{account});
	@reign = split (/ /, $$row{reign}) if (!@reign);
	@reign = () if ($newclass && $newclass ne 'mod');
	
	if ($newpassword)
	{
		my $pass_change=$dbh->prepare("UPDATE ".SQL_ACCOUNT_TABLE." SET password=? WHERE username=?;") or make_error(S_SQLFAIL);
		$pass_change->execute(hide_critical_data($newpassword,SECRET),$user_to_edit) or make_error(S_SQLFAIL);
		$pass_change->finish();
	}

	if ($newclass)
	{
		my $class_change=$dbh->prepare("UPDATE ".SQL_ACCOUNT_TABLE." SET account=? WHERE username=?;") or make_error(S_SQLFAIL);
		$class_change->execute($newclass,$user_to_edit) or make_error(S_SQLFAIL);
		$class_change->finish();
	}

	if ($$row{account} eq 'mod') # If user was a moderator (whether user still is or is being promoted), then update reign string 
	{
		my $reignstring = join (" ", @reign);
		my $reign_change=$dbh->prepare("UPDATE ".SQL_ACCOUNT_TABLE." SET reign=? WHERE username=?;") or make_error(S_SQLFAIL);
		$reign_change->execute($reignstring,$user_to_edit) or make_error(S_SQLFAIL);
		$reign_change->finish();
	}

	$sth->finish();
	
	# Redirect, depending on context.		
	make_http_forward(get_secure_script_name()."?task=admin&board=".$board->path()) if ($username eq $user_to_edit);
	make_http_forward(get_secure_script_name()."?task=staff&board=".$board->path()) if ($username ne $user_to_edit);
}

sub create_user_account($$$$$@)
{
	my ($admin,$user_to_create,$password,$account_type,$management_password,@reign) = @_;
	my ($username, $type) = check_password($admin, 'staff');

	# Sanity checks
	make_error("Insufficient privledges.") if ($type ne 'admin');
	make_error("A username is necessary.") if (!$user_to_create);
	make_error("A password is necessary.") if (!$password);
	make_error("Please input only Latin letters (a-z), numbers (0-9), spaces, and some punctuation marks (_,^,.) for the password.") if ($password !~ /^[\w\^\.]+$/);
	make_error("Please input only Latin letters (a-z), numbers (0-9), spaces, and some punctuation marks (_,^,.) for the username.") if ($user_to_create !~ /^[\w\^\.\s]+$/);
	make_error("Please limit the username to thirty characters maximum.") if (length $user_to_create > 30);
	make_error("Please have a username of at least four characters.") if (length $user_to_create < 4);
	make_error("Please limit the password to thirty characters maximum.") if (length $password > 30);
	make_error("Passwords should be at least eight characters!") if (length $password < 8);
	make_error("No boards specified for local moderator.") if (!@reign && $account_type eq 'mod');
	
	my $sth=$dbh->prepare("SELECT * FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
	$sth->execute($user_to_create) or make_error(S_SQLFAIL);
	my $row = $sth->fetchrow_hashref();
	
	make_error("Username exists.") if ($row);
	make_error("Password for management incorrect.") if ($account_type eq 'admin' && $management_password ne ADMIN_PASS);
	
	my $reignstring = '';
	if ($account_type eq 'mod') # Handle list of boards under jurisdiction if user is to be a local moderator.
	{
		$reignstring = join (" ", @reign);
	}
	
	my $encrypted_password = hide_critical_data($password, SECRET);
	
	$sth->finish();
	
	insert_user_account_entry($user_to_create,$encrypted_password,$reignstring,$account_type);
	
	make_http_forward(get_secure_script_name()."?task=staff&board=".$board->path(),ALTERNATE_REDIRECT);
}

sub insert_user_account_entry($$$$)
{
	my ($username,$encrypted_password,$reignstring,$type) = @_;
	my $sth=$dbh->prepare("INSERT INTO ".SQL_ACCOUNT_TABLE." VALUES (?,?,?,?,?);") or make_error(S_SQLFAIL);
	$sth->execute($username,$type,$encrypted_password,$reignstring,0) or make_error(S_SQLFAIL);
	$sth->finish();
}

sub add_log_entry($$$$$$$) # add in new log entry by column (see init)
{
	trim_staff_log();
	
	my $sth=$dbh->prepare("INSERT INTO ".SQL_STAFFLOG_TABLE." VALUES (null,?,?,?,?,?,?,?);") or make_error(S_SQLFAIL);
	$sth->execute(@_) or make_error(S_SQLFAIL);
	
	$sth->finish();
}

#
# Page Creation
#

sub make_http_header()
{
	print "Content-Type: ".get_xhtml_content_type(CHARSET,USE_XHTML)."\n";
	print "\n";
}

sub get_script_name()
{
	return $ENV{SCRIPT_NAME};
}

sub get_secure_script_name()
{
	return 'https://'.$ENV{SERVER_NAME}.$ENV{SCRIPT_NAME} if(USE_SECURE_ADMIN);
	return $ENV{SCRIPT_NAME};
}

sub expand_image_filename($)
{
	my $filename=shift;

	return expand_filename(clean_path($filename)) unless $board->option('ENABLE_LOAD');

	my ($self_path)=$ENV{SCRIPT_NAME}=~m!^(.*/)[^/]+$!;
	my $src=$board->option('IMG_DIR');
	$filename=~/$src(.*)/;
	return $self_path.$board.'/'.$board->option('REDIR_DIR').clean_path($1).'.html';
}

sub get_reply_link($$)
{
	my ($reply,$parent)=@_;

	return expand_filename($board->option('RES_DIR').$parent.PAGE_EXT).'#'.$reply if($parent);
	return expand_filename($board->option('RES_DIR').$reply.PAGE_EXT);
}

sub get_page_count($$$)
{
	my $total=(shift or count_threads());
	return int(($total+$board->option('IMAGES_PER_PAGE')-1)/$board->option('IMAGES_PER_PAGE'));
}

sub get_filetypes()
{
	my $filetypes=$board->option('FILETYPES');
	$$filetypes{gif}=$$filetypes{jpg}=$$filetypes{png}=1;
	# delete $filetypes{''}; # Yes, such a key can actually exist depending on how configuration is done. O lawd.
	return join ", ",map { uc } sort keys %$filetypes;
}

sub parse_range($$)
{
	my ($ip,$mask)=@_;

	$ip=dot_to_dec($ip) if($ip=~/^\d+\.\d+\.\d+\.\d+$/);

	if($mask=~/^\d+\.\d+\.\d+\.\d+$/) { $mask=dot_to_dec($mask); }
	elsif($mask=~/(\d+)/) { $mask=(~((1<<$1)-1)); }
	else { $mask=0xffffffff; }

	return ($ip,$mask);
}

#
# Post Reporting
#

sub make_report_post_window($@)
{
	my ($from_window, @num) = @_;
	
	# sanity checks
	make_error("No posts selected.") if (!@num);
	make_error("Too many posts. Try reporting the thread or a single post in the case of floods.") if (scalar @num > 10);
	
	my $num_parsed=join (', ', @num); # Use to store the num parameter *and* present to meatbag user
	my $referer = ($from_window) ? '' : escamp($ENV{HTTP_REFERER}); 
	make_http_header();
	print encode_string(POST_REPORT_WINDOW->(stylesheets=>get_stylesheets(),board=>$board, num=>$num_parsed, referer=>$referer ));	
}

sub report_post($$@)
{
	my ($comment,$referer,@posts) = @_;
	my $numip = dot_to_dec($ENV{REMOTE_ADDR});
	my (@errors, $sth, $error_occurred, $board_sql_row, $offender_ip);
	
	make_error('Please input a comment.') if (!$comment);
	make_error('Comment is too long.') if (length $comment > REPORT_COMMENT_MAX_LENGTH);
	make_error('Comment is too short.') if (length $comment < 5);
	make_error("Too many posts. Try reporting the thread or a single post in the case of floods.") if (scalar @posts > 10);
	
	# Ban check
	my $whitelisted=is_whitelisted($numip);
	ban_check($numip,'','','') unless $whitelisted;
	
	# Flood check
	flood_check($numip,time(),$comment,'',0,1);
	
	$comment=format_comment(clean_string(decode_string($comment,CHARSET)));
	
	foreach my $post (@posts)
	{
		if ($post !~ /^\d+$/)
		{
			push @errors, {error=>"$post: Invalid post!"}; 
			$error_occurred = 1;
			next;
		}
		
		# Post check
		$sth=$dbh->prepare('SELECT ip FROM '.$board->option('SQL_TABLE').' WHERE num=?;');
		$sth->execute($post);
		$board_sql_row = $sth->fetchrow_hashref();
		if (!$board_sql_row)
		{
			push @errors, {error=>"$post: Post not found. (It may have just been deleted.)"};
			$error_occurred = 1;
			$sth->finish();
			next;
		}
		else { $offender_ip = $$board_sql_row{ip}; }
		$sth->finish();
		
		# Table row check
		$sth=$dbh->prepare('SELECT * FROM '.SQL_REPORT_TABLE.' WHERE postnum=? AND board=?;');
		$sth->execute($post,$board->path());
		my $row=$sth->fetchrow_hashref();
		
		if ($row)
		{
			push @errors, {error=>"$post: Post has already been reported."} if ($$row{resolved} == 0);
			push @errors, {error=>"$post: This post is marked as resolved."} if ($$row{resolved} != 0);
			$error_occurred = 1;
			$sth->finish();
			next;
		}
		
		# File report
		$sth=$dbh->prepare('INSERT INTO '.SQL_REPORT_TABLE.' VALUES (NULL,?,?,?,?,?,?,?,0);');
		$sth->execute($board->path(),$numip,$offender_ip,$post,$comment,time(),make_date(time()+TIME_OFFSET,DATE_STYLE));
		$sth->finish();
	}
	
	# trim the database
	trim_reported_posts();
	
	# redirect to confirmation page
	make_http_header();
	print encode_string(REPORT_SUBMITTED->(stylesheets=>get_stylesheets(),board=>$board, errors=>\@errors, error_occurred=>$error_occurred, referer=>$referer)); 
}

sub mark_resolved($$$%)
{
	my ($admin, $delete, $caller, %posts) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	my (@errors, $error_occurred, $reign);

	my $referer = $ENV{HTTP_REFERER};	
	
	if ($type eq 'mod')
	{
		my $reigncheck=$dbh->prepare("SELECT reign FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
		$reigncheck->execute($username) or make_error(S_SQLFAIL);
		$reign=($reigncheck->fetchrow_array())[0];
	
	}
	
	my $current_board_name = $board->path();
	undef $board;

	foreach my $board_name (keys %posts)
	{
		$board = Board->new($board_name); # Change the board object so we can delete shit in other boards.
		
		# Access check
		if ($type eq 'mod' && $reign !~ /\b$board_name\b/)
		{
			push @errors, {error=>"$board_name,*: Sorry, you do not have access rights to this board."};
			$error_occurred = 1;
			next;
		}
		
		if ($delete)
		{
			if (!($board->option('SQL_TABLE')))
			{
				push @errors, {error=>"$board_name,*: Cannot delete posts: Board not found."};
				$error_occurred = 1;
				next;
			}
			else
			{
				delete_stuff('',0,0,$admin,1,'internal',@{$posts{$board_name}});
			}
		}
		
		foreach my $post (@{$posts{$board_name}})
		{
			# check presence of row
			my $sth=$dbh->prepare('SELECT * FROM '.SQL_REPORT_TABLE.' WHERE postnum=? AND board=?;') or make_error(S_SQLFAIL);
			$sth->execute($post,$board_name) or make_error(S_SQLFAIL);
			
			if (!(($sth->fetchrow_array())[0]))
			{
				push @errors, {error=>"$board_name,$post: Report not found."};
				$error_occurred = 1;
				$sth->finish();
				next;
			}
			$sth->finish();
			
			$sth=$dbh->prepare('UPDATE '.SQL_REPORT_TABLE.' SET resolved=1 WHERE postnum=? AND board=?;') or make_error(S_SQLFAIL);
			$sth->execute($post,$board_name) or make_error(S_SQLFAIL);
			$sth->finish();
			
			# add staff log entry
			add_log_entry($username,'report_resolve',$board_name.','.$post,make_date(time()+TIME_OFFSET,DATE_STYLE),dot_to_dec($ENV{REMOTE_ADDR}),0,time());
		}
		
		undef $board;
	}
	
	$board = Board->new($current_board_name);
	
	unless ($caller eq 'internal') # Unless being called by delete_stuff()...
	{
		# then redirect to confirmation page.
		make_http_header();
		print encode_string(REPORT_RESOLVED->(stylesheets=>get_stylesheets(),board=>$board, errors=>\@errors, error_occurred=>$error_occurred, admin=>$admin, username=>$username, type=>$type, referer=>$referer));
	}
}

sub make_report_page($$$$$)
{
	my ($admin, $page, $perpage, $sortby, $order) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	my ($sth,@reports,@boards,$where_string,$sortby_string,$resolved_only,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page);
	
	# Restrict view if local moderator
	if ($type eq 'mod')
	{
		$sth=$dbh->prepare("SELECT reign FROM ".SQL_ACCOUNT_TABLE." WHERE username=?;") or make_error(S_SQLFAIL);
		$sth->execute($username) or make_error(S_SQLFAIL);
		@boards = split (/ /, ($sth->fetchrow_array)[0]);
		$sth->finish();
		
		$where_string = "WHERE board=?".(" OR board=?" x $#boards);
	}
	
	# Sorting options
	if ($sortby eq 'board' || $sortby eq 'postnum' || $sortby eq 'date')
	{
		$sortby_string .= $sortby . ' ' . (($order =~ /^asc/i) ? 'ASC' : 'DESC') . (($sortby ne 'date') ? ', date DESC' : '');
	}
	else
	{
		$sortby_string .= 'date DESC';
	}
	
	$resolved_only .= (@boards) ? 'AND resolved=0' : 'WHERE resolved=0';
	
	my $count_get = $dbh->prepare('SELECT COUNT(*) FROM '.SQL_REPORT_TABLE." $where_string $resolved_only;");
	$count_get->execute(@boards) or make_error(S_SQLFAIL);
	my $count = ($count_get->fetchrow_array())[0];

	$page = 1 if ($page !~ /^\d+$/);
	$perpage = 50 if ($perpage !~ /^\d+$/);

	($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	$count_get->finish();
	
	$sth=$dbh->prepare('SELECT board AS board_name,reporter,offender,postnum,comment,date FROM '.SQL_REPORT_TABLE." $where_string $resolved_only ORDER BY $sortby_string LIMIT $perpage OFFSET $offset;");
	$sth->execute(@boards);
	
	while (my $row = $sth->fetchrow_hashref())
	{
		$$row{rowtype}=@reports%2+1;
		push @reports, $row;
	}
	
	$sth->finish();
	
	my @page_setting_hidden_inputs = ({name=>'task', value=>'reports'},{name=>'board',value=>$board->path()},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby});
	
	make_http_header();
	print encode_string(REPORT_PANEL_TEMPLATE->(admin=>$admin,board=>$board,username=>$username,type=>$type,reports=>\@reports,page=>$page,perpage=>$perpage,rowcount=>$count,stylesheets=>get_stylesheets(),rooturl=>get_secure_script_name()."?task=reports&amp;board=".$board->path()."&amp;sortby=$sortby&amp;order=$order",number_of_pages=>$number_of_pages,inputs=>\@page_setting_hidden_inputs)); 
}

sub make_resolved_report_page($$$$$)
{
	my ($admin, $page, $perpage, $sortby, $order) = @_;
	my ($username, $type) = check_password($admin, 'mpanel');
	my ($sth,@reports,@boards,$where_string,$sortby_string,$resolved_only,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page);
	
	# forbid non-admins
	make_error("Insufficient Privledges.") if ($type ne 'admin');
	
	# Sorting options
	if ($sortby eq 'board' || $sortby eq 'postnum' || $sortby eq 'date')
	{
		$sortby_string .= $sortby . ' ' . (($order =~ /^asc/i) ? 'ASC' : 'DESC') . (($sortby ne 'date') ? ', date DESC' : '');
	}
	else
	{
		$sortby_string .= 'date DESC';
	}
	
	my $count_get = $dbh->prepare('SELECT COUNT(*) FROM '.SQL_REPORT_TABLE.' WHERE resolved<>0;');
	$count_get->execute(@boards) or make_error(S_SQLFAIL);
	my $count = ($count_get->fetchrow_array())[0];

	$page = 1 if ($page !~ /^\d+$/);
	$perpage = 50 if ($perpage !~ /^\d+$/);

	($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page) = get_page_limits($page,$perpage,$count);
	$count_get->finish();
	
	$sth=$dbh->prepare('SELECT '.SQL_REPORT_TABLE.'.board AS board_name,'.SQL_REPORT_TABLE.'.reporter,'.SQL_REPORT_TABLE.'.offender,'.SQL_REPORT_TABLE.'.postnum,'.SQL_REPORT_TABLE.'.comment,'.SQL_REPORT_TABLE.'.date,'.SQL_STAFFLOG_TABLE.'.username FROM '.SQL_REPORT_TABLE." LEFT OUTER JOIN ".SQL_STAFFLOG_TABLE." ON CONCAT(".SQL_REPORT_TABLE.".board,',',".SQL_REPORT_TABLE.".postnum)=".SQL_STAFFLOG_TABLE.".info WHERE ".SQL_REPORT_TABLE.".resolved<>0 ORDER BY $sortby_string LIMIT $perpage OFFSET $offset;") or make_error(S_SQLFAIL);
	$sth->execute(@boards) or make_error(S_SQLFAIL);
	
	while (my $row = $sth->fetchrow_hashref())
	{
		$$row{rowtype}=@reports%2+1;
		push @reports, $row;
	}
	
	$sth->finish();
	
	my @page_setting_hidden_inputs = ({name=>'task', value=>'resolvedreports'},{name=>'board',value=>$board->path()},{name=>'order',value=>$order},{name=>'sortby',value=>$sortby});
	
	make_http_header();
	print encode_string(REPORT_PANEL_TEMPLATE->(admin=>$admin,board=>$board,username=>$username,type=>$type,reports=>\@reports,page=>$page,perpage=>$perpage,rowcount=>$count,stylesheets=>get_stylesheets(),resolved_posts_only=>1,rooturl=>get_secure_script_name()."?task=reports&amp;board=".$board->path()."&amp;sortby=$sortby&amp;order=$order",number_of_pages=>$number_of_pages,inputs=>\@page_setting_hidden_inputs)); 
}

sub local_reported_posts() # return array of hash-reference rows of the unresolved posts for current board
{			# It *might* be worthwhile adding on to the SQL to display abbreviated post information. (Naturally the post will be linked to from the reports page.)
	
	my $sth=$dbh->prepare('SELECT reporter,offender,postnum,comment,date,resolved FROM '.SQL_REPORT_TABLE.' WHERE board=? AND resolved=0;');
	$sth->execute($board->path());
	
	my (@reported_posts);
	while (my $row=get_decoded_hashref($sth))
	{
		$$row{rowtype}=@reported_posts%2+1;
		push @reported_posts, $row;
	}
	
	$sth->finish();
	
	@reported_posts;
}

#
# Other
#

sub get_page_limits($$$)
{
	my ($page,$perpage,$count) = @_;

	my $number_of_pages = int (($count+$perpage-1)/$perpage);
	$page = $number_of_pages if ($page > $number_of_pages);
	my $offset = $perpage * ($page - 1);
	$offset = 0 if ($offset < 0);
	my $first_entry_for_page = $offset + 1;
	my $final_entry_for_page = $perpage * $page;

	return ($page,$perpage,$count,$number_of_pages,$offset,$first_entry_for_page,$final_entry_for_page);	
}

sub get_stylesheets(;$) # Grab stylesheets for use in rendered pages
{
	my ($cached_page) = @_;
	my $found=0;
	my @stylesheets=map
	{
		my %sheet;

		$sheet{filename}=$_;
		if ($cached_page eq 'board') # Strip path for use in cached board pages
		{
			my $board_path = $board->path().'/';
			$sheet{filename} =~ s/^$board_path//;
		}
		elsif ($cached_page eq 'thread') # Replace board path with parent dir for use in cached thread pages
		{
			my $board_path = $board->path();
			$sheet{filename} =~ s/^${board_path}/\.\./;	
		}

		($sheet{title})=m!([^/]+)\.css$!i;
		$sheet{title}=ucfirst $sheet{title};
		$sheet{title}=~s/_/ /g;
		$sheet{title}=~s/ ([a-z])/ \u$1/g;
		$sheet{title}=~s/([a-z])([A-Z])/$1 $2/g;

		if($sheet{title} eq $board->option('DEFAULT_STYLE')) { $sheet{default}=1; $found=1; }
		else { $sheet{default}=0; }

		\%sheet;
	} glob($board->path().'/'.$board->option('CSS_DIR')."*.css");

	$stylesheets[0]{default}=1 if(@stylesheets and !$found);

	return \@stylesheets;
}

sub expand_filename($)
{
	my ($filename)=@_;
	return $filename if($filename=~m!^/!);
	return $filename if($filename=~m!^\w+:!);

	my ($self_path)=$ENV{SCRIPT_NAME}=~m!^(.*/)[^/]+$!;
	my $board_path=$board->path().'/';
	return $self_path.$board_path.$filename;
}

sub root_path_to_filename($)
{
	my ($filename) = @_;
	return $filename if($filename=~m!^/!);
	return $filename if($filename=~m!^\w+:!);

	my ($self_path)=$ENV{SCRIPT_NAME}=~m!^(.*/)[^/]+$!;
	return $self_path.$filename;
}
	

#
# Database Auditing and Management
#

sub init_database()
{
	my ($sth);

	$sth=$dbh->do("DROP TABLE ".$board->option('SQL_TABLE').";") if(table_exists($board->option('SQL_TABLE')));
	$sth=$dbh->prepare("CREATE TABLE ".$board->option('SQL_TABLE')." (".

	"num ".get_sql_autoincrement().",".	# Post number, auto-increments
	"parent INTEGER,".			# Parent post for replies in threads. For original posts, must be set to 0 (and not null)
	"timestamp INTEGER,".		# Timestamp in seconds for when the post was created
	"lasthit INTEGER,".			# Last activity in thread. Must be set to the same value for BOTH the original post and all replies!
	"ip TEXT,".					# IP number of poster, in integer form!

	"date TEXT,".				# The date, as a string
	"name TEXT,".				# Name of the poster
	"trip TEXT,".				# Tripcode (encoded)
	"email TEXT,".				# Email address
	"subject TEXT,".			# Subject
	"password TEXT,".			# Deletion password (in plaintext) 
	"comment TEXT,".			# Comment text, HTML encoded.

	"image TEXT,".				# Image filename with path and extension (IE, src/1081231233721.jpg)
	"size INTEGER,".			# File size in bytes
	"md5 TEXT,".				# md5 sum in hex
	"width INTEGER,".			# Width of image in pixels
	"height INTEGER,".			# Height of image in pixels
	"thumbnail TEXT,".			# Thumbnail filename with path and extension
	"tn_width TEXT,".			# Thumbnail width in pixels
	"tn_height TEXT,".			# Thumbnail height in pixels
	"lastedit TEXT,".			# ADDED - Date of previous edit, as a string 
	"lastedit_ip TEXT,".			# ADDED - Previous editor of the post, if any
	"admin_post TEXT,".			# ADDED - Admin post?
	"stickied INTEGER,".		# ADDED - Stickied?
	"locked TEXT".			# ADDED - Locked?
	");") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_admin_database()
{
	my ($sth);

	$sth=$dbh->do("DROP TABLE ".SQL_ADMIN_TABLE.";") if(table_exists(SQL_ADMIN_TABLE));
	$sth=$dbh->prepare("CREATE TABLE ".SQL_ADMIN_TABLE." (".

	"num ".get_sql_autoincrement().",".	# Entry number, auto-increments
	"type TEXT,".				# Type of entry (ipban, wordban, etc)
	"comment TEXT,".			# Comment for the entry
	"ival1 TEXT,".			# Integer value 1 (usually IP)
	"ival2 TEXT,".			# Integer value 2 (usually netmask)
	"sval1 TEXT,".				# String value 1
	"total TEXT,".			# ADDED - Total Ban?
	"expiration INTEGER".		# ADDED - Ban Expiration?
	");") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_proxy_database()
{
	my ($sth);

	$sth=$dbh->do("DROP TABLE ".SQL_PROXY_TABLE.";") if(table_exists(SQL_PROXY_TABLE));
	$sth=$dbh->prepare("CREATE TABLE ".SQL_PROXY_TABLE." (".

	"num ".get_sql_autoincrement().",".	# Entry number, auto-increments
	"type TEXT,".				# Type of entry (black, white, etc)
	"ip TEXT,".				# IP address
	"timestamp INTEGER,".			# Age since epoch
	"date TEXT".				# Human-readable form of date 

	");") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_account_database() # Staff accounts.
{
	my ($sth);
	
	$sth=$dbh->do("DROP TABLE ".SQL_ACCOUNT_TABLE.";") if(table_exists(SQL_ACCOUNT_TABLE));
	$sth=$dbh->prepare("CREATE TABLE ".SQL_ACCOUNT_TABLE." (".
	"username VARCHAR(25) PRIMARY KEY NOT NULL UNIQUE,".	# Name of user--must be unique
	"account TEXT NOT NULL,".				# Account type/class: mod, globmod, admin
	"password TEXT NOT NULL,".				# Encrypted password
	"reign TEXT,".						# List of board (tables) under jurisdiction: globmod and admin have global power and are exempt
	"disabled INTEGER".					# Disabled account?
	");") or make_error(S_SQLFAIL);
	
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_activity_database() # Staff activity log
{
	my ($sth);
	
	$sth=$dbh->do("DROP TABLE ".SQL_STAFFLOG_TABLE.";") if(table_exists(SQL_STAFFLOG_TABLE));
	$sth=$dbh->prepare("CREATE TABLE ".SQL_STAFFLOG_TABLE." (".
	"num ".get_sql_autoincrement().",".	# ID
	"username VARCHAR(25) NOT NULL,".	# Name of moderator involved
	"action TEXT,".				# Action performed: post_delete, admin_post, admin_edit, ip_ban, ban_edit, ban_remove
	"info TEXT,".				# Information
	"date TEXT,".				# Date of action
	"ip TEXT,".				# IP address of the moderator
	"admin_id INTEGER,".			# For associating certain entries with the corresponding key on the admin table
	"timestamp INTEGER".			# Timestamp, for trimming
	");") or make_error(S_SQLFAIL);
	
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_common_site_database() # Index of all the boards sharing the same imageboard site.
{
	my ($sth);
	
	$sth=$dbh->do("DROP TABLE ".SQL_COMMON_SITE_TABLE.";") if table_exists(SQL_COMMON_SITE_TABLE);
	$sth=$dbh->prepare("CREATE TABLE ".SQL_COMMON_SITE_TABLE." (".
	"board VARCHAR(25) PRIMARY KEY NOT NULL UNIQUE,".	# Name of comment table
	"type TEXT".						# Corresponding board type? (Later use)
	");") or make_error(S_SQLFAIL);				# And that's it. Hopefully this is a more efficient solution than handling it all in code or a text file.
	
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();
}

sub init_report_database()
{
	my ($sth);
	
	$sth=$dbh->do("DROP TABLE ".SQL_REPORT_TABLE.";") if table_exists(SQL_REPORT_TABLE);
	$sth=$dbh->prepare("CREATE TABLE ".SQL_REPORT_TABLE." (".
	"num ".get_sql_autoincrement().",".	# Report number, auto-increments
	"board VARCHAR(25) NOT NULL,".		# Board name
	"reporter TEXT NOT NULL,".		# Reporter's IP address (decimal encoded)
	"offender TEXT,".			# IP Address of the offending poster. Why the form-breaking redundancy with SQL_TABLE? If a post is deleted by the perpetrator, the trace is still logged. :)
	"postnum INTEGER NOT NULL,".		# Post number
	"comment TEXT NOT NULL,".		# Mandated reason for the report
	"timestamp INTEGER,".		# Timestamp in seconds for when the post was created
	"date TEXT,".				# Date of the report
	"resolved INTEGER".			# Is it resolved? (1: yes 0: no)
	");") or make_error(S_SQLFAIL);				# And that's it. Hopefully this is a more efficient solution than handling it all in code or a text file.
	
	$sth->execute() or make_error(S_SQLFAIL);
	$sth->finish();	
}

sub repair_database()
{
	my ($sth,$row,@threads,$thread);

	$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE parent=0;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);

	while($row=$sth->fetchrow_hashref()) { push(@threads,$row); }

	foreach $thread (@threads)
	{
		# fix lasthit
		my ($upd);

		$upd=$dbh->prepare("UPDATE ".$board->option('SQL_TABLE')." SET lasthit=? WHERE parent=?;") or make_error(S_SQLFAIL);
		$upd->execute($$row{lasthit},$$row{num}) or make_error(S_SQLFAIL." ".$dbh->errstr());
		$upd->finish();
	}
	$sth->finish();
}

sub get_sql_autoincrement()
{
	return 'INTEGER PRIMARY KEY NOT NULL AUTO_INCREMENT' if(SQL_DBI_SOURCE=~/^DBI:mysql:/i);
	return 'INTEGER PRIMARY KEY' if(SQL_DBI_SOURCE=~/^DBI:SQLite:/i);
	return 'INTEGER PRIMARY KEY' if(SQL_DBI_SOURCE=~/^DBI:SQLite2:/i);

	make_error(S_SQLCONF); # maybe there should be a sane default case instead?
}

sub trim_database()
{
	my ($sth,$row,$order);

	if($board->option('TRIM_METHOD')==0) { $order='num ASC'; }
	else { $order='lasthit ASC'; }

	if($board->option('MAX_AGE') > 0) # needs testing
	{
		my $mintime=time()-($board->option('MAX_AGE'))*3600;

		$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE parent=0 AND timestamp<=$mintime AND stickied<>1;") or make_error(S_SQLFAIL);
		$sth->execute() or make_error(S_SQLFAIL);

		while($row=$sth->fetchrow_hashref())
		{
			delete_post($$row{num},"",0,$board->option('ARCHIVE_MODE'));
		}
	}

	my $threads=count_threads();
	my ($posts,$size)=count_posts();
	my $max_threads=($board->option('MAX_THREADS') > 0) ? ($board->option('MAX_THREADS')) : $threads;
	my $max_posts=($board->option('MAX_POSTS') > 0) ? ($board->option('MAX_POSTS')) : $posts;
	my $max_size=($board->option('MAX_MEGABYTES') > 0) ? ($board->option('MAX_MEGABYTES')*1024*1024) : $size;

	while($threads>$max_threads or $posts>$max_posts or $size>$max_size)
	{
		$sth=$dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE parent=0 AND stickied<>1 ORDER BY $order LIMIT 1;") or make_error(S_SQLFAIL);
		$sth->execute() or make_error(S_SQLFAIL);

		if($row=$sth->fetchrow_hashref())
		{
			my ($threadposts,$threadsize)=count_posts($$row{num});

			delete_post($$row{num},"",0,$board->option('ARCHIVE_MODE'));

			$threads--;
			$posts-=$threadposts;
			$size-=$threadsize;
		}
		else { last; } # shouldn't happen
	}
	
	if ($sth) {$sth->finish();}
}

sub trim_reported_posts(;$)
{
	my ($date) = @_;
	if ($date)
	{
		my $sth=$dbh->prepare("DELETE FROM ".SQL_REPORT_TABLE." WHERE timestamp<=?;") or make_error(S_SQLFAIL);
		$sth->execute(time()-$date) or make_error(S_SQLFAIL);
		$sth->finish();
	}
	elsif (REPORT_RETENTION)
	{
		my $sth=$dbh->prepare("DELETE FROM ".SQL_REPORT_TABLE." WHERE timestamp<=?;") or make_error(S_SQLFAIL);
		$sth->execute(time()-(REPORT_RETENTION)) or make_error(S_SQLFAIL);
		$sth->finish();
	}
}

sub trim_staff_log(;$)
{
	my $date = @_;
	if ($date)
	{
		my $sth=$dbh->prepare("DELETE FROM ".SQL_STAFFLOG_TABLE." WHERE timestamp<=?;") or make_error(S_SQLFAIL);
		$sth->execute(time()-$date) or make_error(S_SQLFAIL);
		$sth->finish();
	}
	elsif (STAFF_LOG_RETENTION)
	{
		my $sth=$dbh->prepare("DELETE FROM ".SQL_STAFFLOG_TABLE." WHERE timestamp<=?;") or make_error(S_SQLFAIL);
		$sth->execute(time()-(STAFF_LOG_RETENTION)) or make_error(S_SQLFAIL);
		$sth->finish();
	}
}

#
# First-Time Setup
#

sub first_time_setup_page()
{
	make_http_header();
	print encode_string(FIRST_TIME_SETUP->(stylesheets=>get_stylesheets(),board=>$board));
	last if $count > $maximum_allowed_loops;
	next;
}

sub first_time_setup_start($)
{
	my ($admin) = @_;
	if ($admin eq ADMIN_PASS)
	{
		make_http_header();
		print encode_string(ACCOUNT_SETUP->(admin=>crypt_password($admin),stylesheets=>get_stylesheets(),board=>$board));
	}
	else
	{
		make_error('Wrong password.');
	}
}

sub first_time_setup_finalize($$$)
{
	my ($admin,$username,$password) = @_;
	make_error("A username is necessary.") if (!$username);
	make_error("A password is necessary.") if (!$password);
	make_error("Please input only Latin letters (a-z), numbers (0-9), spaces, and some punctuation marks (_,^,.) for the password.") if ($password !~ /^[\w\^\.]+$/);
	make_error("Please input only Latin letters (a-z), numbers (0-9), spaces, and some punctuation marks (_,^,.) for the username.") if ($username !~ /^[\w\^\.\s]+$/);
	make_error("Please limit the username to thirty characters maximum.") if (length $username > 30);
	make_error("Please have a username of at least four characters.") if (length $username < 4);
	make_error("Please limit the password to thirty characters maximum.") if (length $password > 30);
	make_error("Passwords should be at least eight characters!") if (length $password < 8);
	
	if ($admin eq crypt_password(ADMIN_PASS))
	{
		init_account_database();
		init_activity_database();
		insert_user_account_entry($username,hide_critical_data($password, SECRET),'','admin');
		make_http_forward(get_secure_script_name."?task=admin&amp;board=".$board->path,ALTERNATE_REDIRECT);

	}
	else
	{
		make_error('Wrong password');
	}
}

sub table_exists($)
{
	my ($table)=@_;
	my ($sth);

	return 0 unless($sth=$dbh->prepare("SELECT * FROM ".$table." LIMIT 1;"));
	return 0 unless($sth->execute());
	$sth->finish();
	return 1;
}

sub count_threads()
{
	my ($sth);

	$sth=$dbh->prepare("SELECT count(*) FROM ".$board->option('SQL_TABLE')." WHERE parent=0;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	my $return = ($sth->fetchrow_array())[0];
	$sth->finish();

	return $return;
}

sub count_posts(;$)
{
	my ($parent)=@_;
	my ($sth,$where);

	$where="WHERE parent=$parent or num=$parent" if($parent);
	$sth=$dbh->prepare("SELECT count(*),sum(size) FROM ".$board->option('SQL_TABLE')." $where;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	my @return = ($sth->fetchrow_array());
	$sth->finish();

	return @return;
}

sub thread_exists($)
{
	my ($thread)=@_;
	my ($sth);

	$sth=$dbh->prepare("SELECT count(*) FROM ".$board->option('SQL_TABLE')." WHERE num=? AND parent=0;") or make_error(S_SQLFAIL);
	$sth->execute($thread) or make_error(S_SQLFAIL);
	my $return = ($sth->fetchrow_array())[0];
	$sth->finish();

	return $return;
}

sub get_decoded_hashref($)
{
	my ($sth)=@_;

	my $row=$sth->fetchrow_hashref();

	if($row and $has_encode)
	{
		for my $k (keys %$row) # don't blame me for this shit, I got this from perlunicode.
		{ defined && /[^\000-\177]/ && Encode::_utf8_on($_) for $row->{$k}; }

		if(SQL_DBI_SOURCE=~/^DBI:mysql:/i) # OMGWTFBBQ
		{ for my $k (keys %$row) { $$row{$k}=~s/chr\(([0-9]+)\)/chr($1)/ge; } }
	}

	return $row;
}

sub get_decoded_arrayref($)
{
	my ($sth)=@_;

	my $row=$sth->fetchrow_arrayref();

	if($row and $has_encode)
	{
		# don't blame me for this shit, I got this from perlunicode.
		defined && /[^\000-\177]/ && Encode::_utf8_on($_) for @$row;

		if(SQL_DBI_SOURCE=~/^DBI:mysql:/i) # OMGWTFBBQ
		{ s/chr\(([0-9]+)\)/chr($1)/ge for @$row; }
	}

	return $row;
}

sub get_boards() # Get array of referenced hashes of all boards
{
	my @boards; # Board list
	my $board_is_present = 0; # Is the current board present?
	
	my $sth = $dbh->prepare("SELECT board AS 'board_entry' FROM ".SQL_COMMON_SITE_TABLE." ORDER BY board;") or make_error(S_SQLFAIL);
	$sth->execute() or make_error(S_SQLFAIL);
	
	while (my $row=$sth->fetchrow_hashref())
	{
		push @boards,$row;
		$board_is_present = 1 if $$row{board_entry} eq $board->path();
	}
	
	$sth->finish();
	
	unless ($board_is_present)
	{
		my $fix = $dbh->prepare("INSERT INTO ".SQL_COMMON_SITE_TABLE." VALUES(?,?);") or make_error(S_SQLFAIL);
		$fix->execute($board->path(),"") or make_error(S_SQLFAIL);
		$fix->finish();
		
		my $row = {board_entry=>$board->path()};
		push @boards, $row;
	}
	
	@boards;
}

#
# Script Management
#

sub abort_user_action()
{
	last if $count > $maximum_allowed_loops;
	next;
}

sub restart_script($)
{
	my $admin = $_[0];
	my ($username, $accounttype) = check_password($admin, 'mpanel');
	if ($accounttype eq "admin")
	{
		make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
		last;
	}
	else
	{
		make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
	}
}

#
# Oekaki
#

sub make_painter($$$$$$$$$)
{
	my ($oek_painter,$oek_x,$oek_y,$oek_parent,$oek_src,$oek_editing,$num,$password,$dummy)=@_;
	my $ip=$ENV{REMOTE_ADDR};
	
	make_error(S_HAXORING) if($oek_x=~/[^0-9]/ or $oek_y=~/[^0-9]/ or $oek_parent=~/[^0-9]/);
	make_error(S_HAXORING) if($oek_src and !($board->option('OEKAKI_ENABLE_MODIFY')));
	make_error(S_HAXORING) if($oek_src=~m![^0-9a-zA-Z/\.]!);
	make_error(S_OEKTOOBIG) if($oek_x>$board->option('OEKAKI_MAX_X') or $oek_y>$board->option('OEKAKI_MAX_Y'));
	make_error(S_OEKTOOSMALL) if($oek_x<$board->option('OEKAKI_MIN_X') or $oek_y<$board->option('OEKAKI_MIN_Y'));
	
	if ($oek_editing)
	{
		my $sth = $dbh->prepare("SELECT password FROM ".$board->option('SQL_TABLE')." WHERE num=?;") or make_error(S_SQLFAIL);
		$sth->execute($num) or make_error(S_SQLFAIL);
		my $row=get_decoded_hashref($sth);
		make_error(S_BADEDITPASS) if ($password ne $$row{password});
		make_error(S_NOPASS) if ($password eq '');
		$sth->finish();
	}
	
	my $time=time;
	
	if($oek_painter=~/shi/)
	{
		my $mode;
		$mode="pro" if($oek_painter=~/pro/);
	
		my $selfy;
		$selfy=1 if($oek_painter=~/selfy/);
	
		print "Content-Type: text/html; charset=Shift_JIS\n";
		print "\n";
	
		print OEKAKI_PAINT_TEMPLATE->(
			oek_painter=>clean_string($oek_painter),
			oek_x=>clean_string($oek_x),
			oek_y=>clean_string($oek_y),
			oek_parent=>clean_string($oek_parent),
			oek_src=>expand_filename(clean_string($oek_src)),
			ip=>$ip,
			time=>$time,
			mode=>$mode,
			selfy=>$selfy,
			oek_editing=>$oek_editing,
			num=>$num,
			password=>$password,
			dummy => $dummy,
			tmp_dir => $board->option('TMP_DIR'),
			board=>$board
		);
	}
	else
	{
		make_error(S_OEKUNKNOWN);
	}
}

sub make_oekaki_finish($$$$$$$)
{
	my $ip=$ENV{REMOTE_ADDR};
	
	my ($num, $dummy, $oek_parent, $srcinfo, $oek_editing, $password, $oek_ip) = @_;
	
	$oek_ip=$ip unless($oek_ip);
	
	make_error('Invalid IP') unless($oek_ip=~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
	
	my $tmpname=$board->option('TMP_DIR').$oek_ip.'.png';
	
	make_http_header();

	if (!$oek_editing)
	{
		print OEKAKI_FINISH_TEMPLATE->(
			tmpname=>$tmpname,
			oek_parent=>clean_string($oek_parent),
			oek_ip=>$oek_ip,
			srcinfo=>clean_string($srcinfo),
			dummy=>$dummy,
			decodedinfo=>OEKAKI_INFO_TEMPLATE->(decode_srcinfo($srcinfo,$board->path().'/'.$tmpname)),
			stylesheets=>get_stylesheets(),
			board=>$board
		);
	}
	else
	{	
		my $sth = $dbh->prepare("SELECT * FROM ".$board->option('SQL_TABLE')." WHERE num = ?;");
		$sth->execute($num);
		my $row = get_decoded_hashref($sth);
		
		print OEKAKI_FINISH_EDIT_TEMPLATE->(
			tmpname=>$tmpname,
			oek_parent=>clean_string($oek_parent),
			oek_ip=>$oek_ip,
			srcinfo=>clean_string($srcinfo),
			decodedinfo=>OEKAKI_EDIT_INFO_TEMPLATE->(decode_srcinfo($srcinfo,$tmpname)),
			num=>$num,
			dummy => $dummy,
			comment=>tag_killa($$row{comment}),
			name=>$$row{name},
			email=>$$row{email},
			subject=>$$row{subject},
			trip=>$$row{trip},
			password=>$password,
			stylesheets=>get_stylesheets(),
			board=>$board
		);
		$sth->finish();
	}
}

sub pretty_age($)
{
	my ($age)=@_;

	return "HAXORED" if($age<0);
	return $age." s" if($age<60);
	return int($age/60)." min" if($age<3600);
	return int($age/3600)." h ".int(($age%3600)/60)." min" if($age<3600*24*7);
	return "HAXORED";
}

sub decode_srcinfo($$)
{
	my ($srcinfo,$tmpname)=@_;
	my @info=split /,/,$srcinfo;
	my @stat=stat $tmpname;
	my $fileage=$stat[9];
	my $source = $info[2];
	my $path = $board->path().'/';
	$source =~ s/^\/?${path}//;
	my ($painter)=grep { $$_{painter} eq $info[1] } @{S_OEKPAINTERS()};

	return (
		time=>clean_string(pretty_age($fileage-$info[0])),
		painter=>clean_string($$painter{name}),
		source=>clean_string($source),
	);
}

#
# Main Loop
#

while ( $query = new CGI::Fast )
{
	$handling_request = 1;
	
	$count++;
	
	# It may be nicer to put this outside the loop... but the database connection seems to expire and stay dead unless it is put in here.
	$dbh=get_conn(); 

	my $board_name=($query->param("board"));
	if ((! -e './'.$board_name) || !$board_name || $board_name eq "include")
	{
		print ("Content-type: text/plain\n\nBoard not found.");
		next;
	}
	if (! -e './'.$board_name.'/board_config.pl')
	{
		print ("Content-type: text/plain\n\nBoard configuration not found.");
		next;
	}
	
	$board = Board->new($board_name);

	# check for admin table
	init_admin_database() if(!table_exists(SQL_ADMIN_TABLE));
	
	# check for proxy table
	init_proxy_database() if(!table_exists(SQL_PROXY_TABLE));
	
	# check for common site table
	init_common_site_database() if (!table_exists(SQL_COMMON_SITE_TABLE));
	
	# check for report table
	init_report_database() if (!table_exists(SQL_REPORT_TABLE));
	
	# check for staff accounts
	first_time_setup_page() if (!table_exists(SQL_ACCOUNT_TABLE) && $query->param("task") ne 'entersetup' && !$query->param("admin"));
	
	# check for staff accounts
	init_activity_database() if (!table_exists(SQL_STAFFLOG_TABLE) && $query->param("task") ne 'entersetup' && !$query->param("admin"));	
	
	# Check for .htaccess
	
	if (! -e HTACCESS_PATH.".htaccess")
	{
		open (HTACCESSMAKE, ">.htaccess");
		print HTACCESSMAKE "RewriteEngine On\nOptions +FollowSymLinks +ExecCGI\n\n";
		close HTACCESSMAKE;
	}
	
	if(!table_exists($board->option('SQL_TABLE'))) # check for comments table
	{
		init_database();
		build_cache();
		make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
		abort_user_action();
	}
	
	my $task=($query->param("task") or $query->param("action"));
	
	# Check for and remove old bans
	my $oldbans=$dbh->prepare("SELECT ival1, total FROM ".SQL_ADMIN_TABLE." WHERE expiration <= ".time()." AND expiration <> 0 AND expiration IS NOT NULL;");
	$oldbans->execute() or make_error(S_SQLFAIL);
	my @unbanned_ips;
	while (my $banrow = get_decoded_hashref($oldbans))
	{
		push @unbanned_ips, $$banrow{ival1};
		if ($$banrow{total} eq 'yes')
		{
			my $ip = dec_to_dot($$banrow{ival1});
			remove_htaccess_entry($ip);
		}
	}
	
	$oldbans->finish();
	
	foreach (@unbanned_ips)
	{	
		my $removeban = $dbh->prepare("DELETE FROM ".SQL_ADMIN_TABLE." WHERE ival1=?") or make_error(S_SQLFAIL);
		$removeban->execute($_) or make_error(S_SQLFAIL);
		$removeban->finish();
	}
	
	# Determine what is to be done, based on task parameter.
	if(!$task)
	{
		build_cache() unless -e $board->path().'/'.$board->option('HTML_SELF');
		make_http_forward($board->path().'/'.$board->option('HTML_SELF'),ALTERNATE_REDIRECT);
	}
	
	# Posting
	elsif($task eq "post")
	{
		my $parent=$query->param("parent");
		my $name=$query->param("field1");
		my $email=$query->param("email");
		my $subject=$query->param("subject");
		my $comment=$query->param("comment");
		my $file=$query->param("file");
		my $password=$query->param("password");
		my $nofile=$query->param("nofile");
		my $captcha=$query->param("captcha");
		my $admin = $query->cookie("wakaadmin");
		my $no_captcha=$query->param("no_captcha");
		my $no_format=$query->param("no_format");
		my $sticky=$query->param("sticky");
		my $lock=$query->param("lock");
		my $admin_post = $query->param("adminpost");
		# (postfix removed--oekaki only)
	
		post_stuff($parent,$name,$email,$subject,$comment,$file,$file,$password,$nofile,$captcha,$admin,$no_captcha,$no_format,'',$sticky,$lock,$admin_post);
	}
	
	# Management
	elsif($task eq "admin")
	{
		my $password=$query->param("berra"); # lol obfuscation
		my $username=$query->param("desu"); # Fuck yes, you are the best obfuscation ever! 
		my $nexttask=$query->param("nexttask");
		my $savelogin=$query->param("savelogin");
		my $admincookie=$query->cookie("wakaadmin");
	
		do_login($username,$password,$nexttask,$savelogin,$admincookie);
	}
	elsif($task eq "logout")
	{
		do_logout();
	}
	elsif($task eq "mpanel")
	{
		my $admin = $query->cookie("wakaadmin");
		my $page = $query->param("page");
		make_admin_post_panel($admin,$page);
	}
	elsif($task eq "deleteall")
	{
		my $admin = $query->cookie("wakaadmin");
		my $ip=$query->param("ip");
		my $mask=$query->param("mask");
		delete_all($admin,$ip,$mask,'');
	}
	elsif($task eq "bans")
	{
		my $admin = $query->cookie("wakaadmin");
		my $ip=$query->param("ip");
		make_admin_ban_panel($admin,$ip);
	}
	elsif($task eq "banthread")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num=$query->param("num");
		add_thread_ban_window($admin,$num);
	}
	elsif($task eq "banthreadconfirm")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num=$query->param("num");
		my $comment=$query->param("comment");
		my $expiration = $query->param("expiration");
		my $total = $query->param("total");
		my $delete=$query->param("delete");
		ban_thread($admin,$num,$comment,$expiration,$total,$delete);
	}
	elsif($task eq "banpopup")
	{
		my $admin = $query->cookie("wakaadmin");
		my $delete=$query->param("delete"); # Post to delete, if any
		my @ip=$query->param("ip");
		add_ip_ban_window($admin,$delete,@ip);
	}
	elsif($task eq "addipfrompopup")
	{
		my $admin = $query->cookie("wakaadmin");
		my $delete=$query->param("delete"); # Post to delete, if any
		my $delete_all=$query->param("deleteall"); # Delete All?
		my @ip=$query->param("ip");
		my $comment=$query->param("comment");
		my $mask=$query->param("mask");
		my $total=$query->param("total");
		my $expiration=$query->param("expiration");
		confirm_ip_ban($admin,$comment,$mask,$total,$expiration,$delete,$delete_all,@ip);
	}
	elsif($task eq "addip")
	{
		my $admin = $query->cookie("wakaadmin");
		my $type=$query->param("type");
		my $comment=$query->param("comment");
		my $ip=$query->param("ip");
		my $mask=$query->param("mask");
		my $total=$query->param("total");
		my $expiration=$query->param("expiration");
		add_admin_entry($admin,$type,$comment,$ip,$mask,'',$total,$expiration,'board'); 
	}
	elsif($task eq "addstring")
	{
		my $admin = $query->cookie("wakaadmin");
		my $type=$query->param("type");
		my $string=$query->param("string");
		my $comment=$query->param("comment");
		add_admin_entry($admin,$type,$comment,0,0,$string,'','','board');
	}
	elsif($task eq "removeban")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num=$query->param("num");
		remove_admin_entry($admin,$num,0,0);
	}
	elsif($task eq "proxy")
	{
		my $admin = $query->cookie("wakaadmin");
		make_admin_proxy_panel($admin);
	}
	elsif($task eq "addproxy")
	{
		my $admin = $query->cookie("wakaadmin");
		my $type=$query->param("type");
		my $ip=$query->param("ip");
		my $timestamp=$query->param("timestamp");
		my $date=make_date(time(),DATE_STYLE);
		add_proxy_entry($admin,$type,$ip,$timestamp,$date);
	}
	elsif($task eq "removeproxy")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num=$query->param("num");
		remove_proxy_entry($admin,$num);
	}
	elsif($task eq "spam")
	{
		my $admin = $query->cookie("wakaadmin");
		make_admin_spam_panel($admin);
	}
	elsif($task eq "updatespam")
	{
		my $admin = $query->cookie("wakaadmin");
		my $spam=$query->param("spam");
		update_spam_file($admin,$spam);
	}
	elsif($task eq "sqldump")
	{
		my $admin = $query->cookie("wakaadmin");
		make_sql_dump($admin);
	}
	elsif($task eq "sql")
	{
		my $admin = $query->cookie("wakaadmin");
		my $nuke=$query->param("nuke");
		my $sql=$query->param("sql");
		make_sql_interface($admin,$nuke,$sql);
	}
	elsif($task eq "mpost")
	{
		my $admin = $query->cookie("wakaadmin");
		make_admin_post($admin);
	}
	elsif($task eq "rebuild")
	{
		my $admin = $query->cookie("wakaadmin");
		do_rebuild_cache($admin);
	}
	elsif($task eq "rebuildglobal")
	{
		my $admin = $query->cookie("wakaadmin");
		do_global_rebuild_cache($admin);
	}
	elsif($task eq "nuke")
	{
		my $admin = $query->cookie("wakaadmin");
		my $nuke = $query->param("nuke");
		do_nuke_database($admin, $nuke);
	}
	elsif($task eq "banreport")
	{
		host_is_banned(dot_to_dec($ENV{REMOTE_ADDR}));
	}
	elsif($task eq "adminedit")
	{
		my $admin = $query -> cookie("wakaadmin");
		my $num = $query->param("num");
		my $type = $query->param("type");
		my $comment = $query->param("comment");
		my $ival1 = $query->param("ival1");
		my $ival2 = $query->param("ival2");
		my $sval1 = $query->param("sval1");
		my $total = $query->param("total");
		my $sec = $query->param("sec"); # Expiration Info
		my $min = $query->param("min");
		my $hour = $query->param("hour");
		my $day = $query->param("day");
		my $month = $query->param("month");
		my $year = $query->param("year");
		my $noexpire = $query->param("noexpire");
		edit_admin_entry($admin,$num,$type,$comment,$ival1,$ival2,$sval1,$total,$sec,$min,$hour,$day,$month,$year,$noexpire);
	}
	elsif($task eq "baneditwindow")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num = $query->param("num");
		make_admin_ban_edit($admin, $num);	
	}
	
	# Post Deletion and Editing
	elsif(lc($task) eq lc(S_DELETE) || lc($task) eq lc(S_MPDELETE))
	{
		my $password = ($query->param("singledelete")) ? $query->param("postpassword") : $query->param("password");
		my $fileonly = ($query->param("singledelete")) ? $query->param("postfileonly") : $query->param("fileonly");
		my $archive=$query->param("archive");
		my $caller = $query->param("caller"); # Is it from a window or a collapsable field?
		my $admin=$query->cookie("wakaadmin");
		my $admin_delete = $query->param("admindelete");
		my @posts = ($query->param("singledelete")) ? $query->param("deletepost") : $query->param("num");
	
		delete_stuff($password,$fileonly,$archive,$admin,$admin_delete,$caller,@posts);
	}
	elsif(lc($task) eq lc(S_MPARCHIVE))
	{
		my $password = ($query->param("singledelete")) ? $query->param("postpassword") : $query->param("password");
		my $fileonly = ($query->param("singledelete")) ? $query->param("postfileonly") : $query->param("fileonly");
		my $caller = $query->param("caller"); # Is it from a window or a collapsable field?
		my $admin=$query->cookie("wakaadmin");
		my $admin_delete = $query->param("admindelete");
		my @posts = ($query->param("singledelete")) ? $query->param("deletepost") : $query->param("num");
	
		delete_stuff($password,$fileonly,1,$admin,$admin_delete,$caller,@posts);
	}
	elsif($task eq "editpostwindow")
	{
		my $num = $query->param("num");
		my $password = $query->param("password");
		my $admin = $query->cookie("wakaadmin");
		my $admin_edit = $query->param("admineditmode");
		edit_window($num, $password, $admin, $admin_edit);
	}
	elsif($task eq "delpostwindow")
	{
		my $num = $query->param("num");
		password_window($num, '', "delete");
	}
	elsif($task eq "editpost")
	{
		my $num = $query->param("num");
		my $name = $query->param("field1");
		my $email = $query->param("email");
		my $subject=$query->param("subject");
		my $comment=$query->param("comment");
		my $file=$query->param("file");
		my $captcha=$query->param("captcha");
		my $admin = $query->cookie("wakaadmin");               
		my $no_captcha=$query->param("no_captcha");
		my $no_format=$query->param("no_format");
		my $postfix=$query->param("postfix");
		my $password = $query->param("password");
		my $killtrip = $query->param("killtrip");
		my $admin_edit = $query->param("adminedit");
		edit_shit($num,$name,$email,$subject,$comment,$file,$file,$password,$captcha,$admin,$no_captcha,$no_format,$postfix,$killtrip,$admin_edit);
	}
	elsif($task eq "edit")
	{
		my $num = $query->param("num");
		my $admin_post = $query->param("admin_post");
		password_window($num, $admin_post, "edit");
	}
	
	# Administrative Thread Management
	elsif($task eq "sticky")
	{
		my $num = $query->param("thread");
		my $admin = $query->cookie("wakaadmin");
		sticky($num, $admin);
	}
	elsif($task eq "unsticky")
	{
		my $num = $query->param("thread");
		my $admin = $query->cookie("wakaadmin");
		unsticky($num, $admin);
	}
	elsif($task eq "lock")
	{
		my $num = $query->param("thread");
		my $admin = $query->cookie("wakaadmin");
		lock_thread($num, $admin);
	}
	elsif($task eq "unlock")
	{
		my $num = $query->param("thread");
		my $admin = $query->cookie("wakaadmin");
		unlock_thread($num, $admin);
	}
	
	# First-time Wakaba Setup
	elsif($task eq "entersetup")
	{
		my $password = $query->param("berra");
		first_time_setup_start($password);
	}
	elsif ($task eq "setup")
	{
		my $username = $query->param("username");
		my $password = $query->param("password");
		my $admin = $query->param("admin");
		first_time_setup_finalize($admin,$username,$password);
	}
	elsif ($task eq "staff")
	{
		my $admin = $query->cookie("wakaadmin");
		manage_staff($admin);
	}
	
	# Staff Management Panels
	elsif ($task eq "deleteuserwindow")
	{
		my $admin = $query->cookie("wakaadmin");
		my $username = $query->param("username");
		make_remove_user_account_window($admin,$username);
	}
	elsif ($task eq "disableuserwindow")
	{
		my $admin = $query->cookie("wakaadmin");
		my $username = $query->param("username");
		make_disable_user_account_window($admin,$username);
	}
	elsif ($task eq "enableuserwindow")
	{
		my $admin = $query->cookie("wakaadmin");
		my $username = $query->param("username");
		make_enable_user_account_window($admin,$username);
	}
	elsif ($task eq "edituserwindow")
	{
		my $admin = $query->cookie("wakaadmin");
		my $username = $query->param("username");
		make_edit_user_account_window($admin,$username);
	}
	elsif ($task eq "reports")
	{
		my $admin = $query->cookie("wakaadmin");
		my $page = $query-> param("page");
		my $perpage = $query->param("perpage");
		my $sortby = $query->param("sortby");
		my $order = $query->param("order");
		make_report_page($admin, $page, $perpage, $sortby, $order);
	}
	elsif ($task eq "resolvedreports")
	{
		my $admin = $query->cookie("wakaadmin");
		my $page = $query-> param("page");
		my $perpage = $query->param("perpage");
		my $sortby = $query->param("sortby");
		my $order = $query->param("order");
		make_resolved_report_page($admin, $page, $perpage, $sortby, $order);
	}
	
	# Post Searching (Admin Only)
	elsif ($task eq "searchposts")
	{
		my $admin = $query->cookie("wakaadmin");
		my $search_type = ($query->param('ipsearch')) ? 'ip' : 'id';
		my $query_string = $query->param($search_type);
		my $page = $query->param('page');
		my $perpage = $query->param('perpage');
		my $caller = $query->param('caller');
		
		search_posts($admin, $search_type, $query_string, $page, $perpage, $caller);
	}

	# Oekaki Stuff
	elsif ($task eq "paint")
	{
		my $oek_painter=$query->param("oek_painter");
		my $oek_x=$query->param("oek_x");
		my $oek_y=$query->param("oek_y");
		my $oek_parent=$query->param("oek_parent");
		my $oek_src=$query->param("oek_src");
		my $oek_editing=$query->param("oek_editing");
		my $num=$query->param("num");
		my $password=$query->param("password");
		my $dummy=$query->param("dummy");
		make_painter($oek_painter,$oek_x,$oek_y,$oek_parent,$oek_src,$oek_editing,$num,$password,$dummy);
	}
	elsif ($task eq "finishpaint")
	{
		my $num=$query->param("num");
		my $dummy=$query->param("dummy");
		my $oek_parent=$query->param("oek_parent");
		my $srcinfo=$query->param("srcinfo");
		my $oek_editing=$query->param("oek_editing");
		my $password=$query->param("password");
		my $oek_ip=$query->param("oek_ip");
		make_oekaki_finish($num, $dummy, $oek_parent, $srcinfo, $oek_editing, $password, $oek_ip);
	}
	elsif ($task eq "oekakipost")
	{
		my $parent=$query->param("parent");
		my $oek_ip=$query->param("oek_ip");
		$oek_ip ||= $ENV{REMOTE_ADDR};
		abort_user_action() unless($oek_ip=~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
		my $tmpname=($board->path().'/'.$board->option('TMP_DIR').$oek_ip.'.png'); # Open up the oekaki the user has uploaded...
		open (TMPFILE,$tmpname) or make_error("Can't read uploaded file");
		my $name=$query->param("field1");
		my $email=$query->param("email");
		my $subject=$query->param("subject");
		my $comment=$query->param("comment");
		my $password=$query->param("password");
		my $captcha=$query->param("captcha");
		my $srcinfo=$query->param("srcinfo");
		
		post_stuff($parent,$name,$email,$subject,$comment,\*TMPFILE,$tmpname,$password,0,$captcha,'',0,0,OEKAKI_INFO_TEMPLATE->(decode_srcinfo($srcinfo,$tmpname)),0,0,0);
		
		close TMPFILE;
		unlink $tmpname;
	}
	elsif ($task eq "oekakiedit")
	{
		my $num=$query->param("num");
		my $oek_ip=$query->param("oek_ip");
		$oek_ip ||= $ENV{REMOTE_ADDR};
		abort_user_action() unless($oek_ip=~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/);
		my $tmpname=$board->path().'/'.$board->option('TMP_DIR').$oek_ip.'.png';
		open TMPFILE,$tmpname or make_error("Can't read uploaded file");
		my $name=$query->param("field1");
		my $email=$query->param("email");
		my $subject=$query->param("subject");
		my $comment=$query->param("comment");
		my $password=$query->param("password");
		my $captcha=$query->param("captcha");
		my $srcinfo=$query->param("srcinfo");
		my $killtrip=$query->param("killtrip");

		edit_shit($num,$name,$email,$subject,$comment,\*TMPFILE,$tmpname,$password,$captcha,'',0,0,OEKAKI_EDIT_INFO_TEMPLATE->(decode_srcinfo($srcinfo,$tmpname)),$killtrip,0);

		close TMPFILE;
		unlink $tmpname;
	}

	# Post Reporting Subroutines
	elsif (lc($task) eq "report")
	{
		my @num = $query->param("num");
		my $from_window = $query->param("popupwindow");
		make_report_post_window($from_window,@num);
	}
	elsif ($task eq "confirmreport")
	{
		my @num = split(/, /, $query->param("num"));
		my $comment = $query->param("comment");
		my $referer = $query->param("referer");
		report_post($comment,$referer,@num)
	}
	elsif ($task eq "resolve")
	{
		my $admin = $query->cookie("wakaadmin");
		my $delete = $query->param("delete");
		my @num = $query->param('num');
		my %posts;
		foreach my $string (@num)
		{
			my ($board_name, $post) = split (/-/, $string);
			push(@{$posts{$board_name}}, $post);
		}
		mark_resolved($admin,$delete,'',%posts);
	}
	
	# Staff Management Subroutines
	elsif ($task eq "createuser")
	{
		my $admin = $query->cookie("wakaadmin");
		my $management_password = $query->param("mpass"); # Necessary for creating in Admin class
		my $username = $query->param("usernametocreate");
		my $password = $query->param("passwordtocreate");
		my $type = $query->param("account");
		my @reign = $query->param("reign");
		create_user_account($admin,$username,$password,$type,$management_password,@reign);
	}
	elsif ($task eq "deleteuser")
	{
		my $admin = $query->cookie("wakaadmin");
		my $management_password = $query->param("mpass"); # Necessary for deleting Admin class 
		my $username = $query->param("username");
		remove_user_account($admin,$username,$management_password);
	}
	elsif ($task eq "disableuser")
	{
		my $admin = $query->cookie("wakaadmin");
		my $management_password = $query->param("mpass"); # Necessary for changing Admin class properites 
		my $username = $query->param("username");
		disable_user_account($admin,$username,$management_password);
	}
	elsif ($task eq "enableuser")
	{
		my $admin = $query->cookie("wakaadmin");
		my $management_password = $query->param("mpass");
		my $username = $query->param("username");
		enable_user_account($admin,$username,$management_password);
	}
	elsif ($task eq "edituser")
	{
		my $admin = $query->cookie("wakaadmin");
		my $management_password = $query->param("mpass");
		my $username = $query->param("usernametoedit");
		my $newpassword = $query->param("newpassword");
		my $newclass = $query->param("newclass");
		my $originalpassword = $query->param("originalpassword");
		my @reign = $query->param("reign");
		edit_user_account($admin,$management_password,$username,$newpassword,$newclass,$originalpassword,@reign);
	}
	elsif ($task eq "staffedits")
	{
		my $admin = $query->cookie("wakaadmin");
		my $num = $query->param("num");
		show_staff_edit_history($admin,$num);
	}
	
	# Staff Logging
	elsif ($task eq "stafflog")
	{
		my $admin = $query->cookie("wakaadmin");
		my $view = $query->param("view");
		my $user_to_view = $query->param("usertoview");
		my $action_to_view = $query->param("actiontoview");
		my $ip_to_view = $query->param("iptoview");
		my $post_to_view = $query->param("posttoview");
		my $sortby = $query->param("sortby");
		my $order = $query->param("order");
		my $page = $query->param("page");
		my $perpage = $query->param("perpage");
		make_staff_activity_panel($admin,$view,$user_to_view,$action_to_view,$ip_to_view,$post_to_view,$sortby,$order,$page,$perpage);
	}
	
	# Script Shutdown for FastCGI
	elsif ($task eq "restart")
	{
		my $admin = $query->cookie("wakaadmin");
		restart_script($admin);
	}
	
	# Fuck, why did you do this?
	else
	{
		make_error("Invalid task.");
	}
	
	$dbh->disconnect();
	
	# Automatically restart on script change
	warn ("Script change detected of $ENV{SCRIPT_NAME}!") and last if (-M $ENV{SCRIPT_FILENAME} < 0);
	warn ("Script change detected of ".expand_filename('config.pl')."!") and last if (-M 'config.pl' < 0);
	
	$handling_request = 0;
	
	if ($count > $maximum_allowed_loops)
	{
		$count = 0;
		last; # Hoping this will help with memory leaks. fork() may be preferable
	}
	last if ($exit_requested);
}

#
# Board Class
# Handles properties of a particular board
#

# Constructor:
# $board_object = Board->new("current_board_name");
# Instance Methods:
# $board_name = $board_object->path();
# $silly_anonymous_option = $board_object->option('SILLY_ANONYMOUS');  

package Board;

my %options;

sub new()
{
	my $self = shift;
	my $board = shift;
	bless \$board, $self;
}

sub option()
{
	my $board = shift;
	my $option = shift;
	
	return $options{$$board}->{$option} if defined($options{$$board}); # Options already known? Return called option.
		
	# Grab code from config file and evaluate.
	open (BOARDCONF, './'.$$board.'/board_config.pl') or return 0;
	binmode BOARDCONF; # Needed for files using non-ASCII characters.
	
	my $board_options_code = do { local $/; <BOARDCONF> };

	$options{$$board} = eval $board_options_code; # Set up hash.
	
	#main::make_error("There is an error in the board's configuration: $@") if ($@ or !%option);
	die ("Board configuration error: ".$@) if $@;
	
	return $options{$$board}->{$option};
	
	close BOARDCONF;
}

sub path()
{
	my $self = shift;
	return $$self;
}
