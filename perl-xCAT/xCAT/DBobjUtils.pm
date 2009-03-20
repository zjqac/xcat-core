#!/usr/bin/env perl -w
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html

#####################################################
#
#   Utility subroutines that can be used to manage xCAT data object
#			definitions.
#
#
#####################################################
package xCAT::DBobjUtils;

use xCAT::NodeRange;
use xCAT::Schema;
use xCAT::Table;
use xCAT::Utils;
use xCAT::MsgUtils;
use strict;

#  IPv6 not yet implemented - need Socket6
use Socket;

#----------------------------------------------------------------------------

=head3   getObjectsOfType

        Get a list of data objects of the given type.

        Arguments:
        Returns:
                undef
                @objlist - list of objects of this type
        Globals:
        Error:
        Example:
        Comments:

		@objlist = xCAT::DBobjUtils->getObjectsOfType($type);

=cut

#-----------------------------------------------------------------------------
sub getObjectsOfType
{
    my ($class, $type) = @_;

    my @objlist;

    # special case for site table
    if ($type eq 'site')
    {
        push(@objlist, 'clustersite');
        return @objlist;
    }

    if ($::saveObjList{$type})
    {
        @objlist = @{$::saveObjList{$type}};
    }
    else
    {

        # get the key for this type object
        # 	ex. for "network" type the key is "netname"
        # get the data type spec from Schema.pm
        my $datatype = $xCAT::Schema::defspec{$type};

        # get the key for this type object
        #   ex. for "network" type the key is "netname"
        my $objkey = $datatype->{'objkey'};

        my $table;
        my $tabkey;
        foreach my $this_attr (@{$datatype->{'attrs'}})
        {
            my $attr = $this_attr->{attr_name};
            if ($attr eq $objkey)
            {

                # get the table & key for to lookup
                # get the actual attr name to use in the table
                #   - may be different then the attr name used for the object.
                ($table, $tabkey) = split('\.', $this_attr->{tabentry});
            }
        }

        # get the whole table and add each entry in the objkey column
        #   to the list of objects.

        my @TableRowArray = xCAT::DBobjUtils->getDBtable($table);

        foreach (@TableRowArray)
        {
            push(@objlist, $_->{$tabkey});

        }

		# if this is type "group" we need to check the nodelist table
		my @nodeGroupList=();
		if ($type eq 'group')
		{
			my $table = "nodelist";
			my @TableRowArray = xCAT::DBobjUtils->getDBtable($table);
			foreach (@TableRowArray)
			{
				my @tmplist = split(',', $_->{'groups'});
				push(@nodeGroupList, @tmplist);
			}
			foreach my $n (@nodeGroupList)
			{
				if (!grep(/^$n$/, @objlist) ) {
					push(@objlist, $n);
				}
			}
		}
		

        @{$::saveObjList{$type}} = @objlist;

    }

    return @objlist;
}

#----------------------------------------------------------------------------

=head3   getobjattrs

        Get data from tables 

        Arguments:
        Returns:
                undef
                hash ref - (ex. $tabhash{$table}{$objname}{$attr} = $value)
        Globals:
        Error:
        Example:

                %tabhash = xCAT::DBobjUtils->getobjattrs(\%typehash);

        Comments:
			For now - only support tables that have 'node' as key !!!
=cut

#-----------------------------------------------------------------------------
sub getobjattrs
{
    my ($class, $ref_hash) = @_;
	my %typehash = %$ref_hash;

	my %tableattrs;
	my %tabhash;

	# get a list of object names for each type
	my %objtypelist;
	foreach my $objname (sort (keys %typehash)) {
		# get list of objects for each type
		# $objtypelist{$typehash{$objname}}=$objname;
		push @{$objtypelist{$typehash{$objname}}}, $objname;
	}

	# go through each object type and look up all the info for each object
	foreach my $objtype (keys %objtypelist) {

		# only do node type for now 
	  	if ($objtype eq 'node') {

			# find the list of tables and corresponding attrs 
			#	- for this object type
			# get the object type decription from Schema.pm
        	my $datatype = $xCAT::Schema::defspec{$objtype};

        	foreach my $this_attr (@{$datatype->{'attrs'}}) {
            	my $attr = $this_attr->{attr_name};

				# table_attr is the attr that actually appears in the
            	#  table which could possibly be different then the attr
            	#  used in the node def
				# ex. 'nodetype.arch'
				my ($lookup_table, $table_attr) = split('\.', $this_attr->{tabentry});
				if (!grep(/^$table_attr$/, @{$tableattrs{$lookup_table}})) {
					push @{$tableattrs{$lookup_table}}, $table_attr;
				}
        	}

			# foreach table look up the list of attrs for this 
			#	list of object names
			foreach my $table (keys %tableattrs) {
				# open the table
				my $thistable = xCAT::Table->new($table, -create => 1, -autocommit => 0);
				if (!$thistable) {
					my $rsp;
					$rsp->{data}->[0] = "Could not get the \'$thistable\' table.";
					xCAT::MsgUtils->message("E", $rsp, $::callback);
				}

				my @objlist = @{$objtypelist{$objtype}};

				my $rec = $thistable->getNodesAttribs(\@objlist, @{$tableattrs{$table}});

				# fill in %tabhash with any values that are set
				foreach my $n (@objlist) {
					my $tmp1=$rec->{$n}->[0];
					foreach $a (@{$tableattrs{$table}}) {
						if (defined($tmp1->{$a})) {
							$tabhash{$table}{$n}{$a} = $tmp1->{$a};
						}
					}
				}
				$thistable->commit;
			}
	  	}
	}
	return %tabhash;
}

#----------------------------------------------------------------------------

=head3   getobjdefs

        Get object definitions from the DB.

        Arguments:
        Returns:
                undef - error
                hash ref - $objecthash{objectname}{attrname} = value
        Globals:
        Error:
        Example:

		To use create hash for objectname and object type
            ex. $objhash{$obj} = $type;

        - then call as follows:
			%myhash = xCAT::DBobjUtils->getobjdefs(\%objhash);

        Comments:

=cut

#-----------------------------------------------------------------------------
sub getobjdefs
{
    my ($class, $hash_ref) = @_;
    my %objhash;
    my %typehash = %$hash_ref;
	my %tabhash;

	@::foundTableList = ();
	
	if ($::ATTRLIST eq "none") {
        # just return the list of obj names
        foreach my $objname (sort (keys %typehash))
        {
            my $type = $typehash{$objname};
            $objhash{$objname}{'objtype'} = $type;
        }
        return %objhash;
    }

	# see if we need to get any objects of type 'node' 
	my $getnodes=0;
	foreach my $objname (keys %typehash) {
		if ($typehash{$objname} eq 'node') {
			$getnodes=1;
		}
	}

	# if so then get node info from tables now
    #   still may need to look up values in some tables using
    #   other keys - also need to figure out what tables to take
    #   values from when using 'only_if' - see below
	# - but this saves lots of time
	if ($getnodes) {
		%tabhash = xCAT::DBobjUtils->getobjattrs(\%typehash);
	}

    foreach my $objname (sort (keys %typehash))
    {
        # need a special case for the site table - for now !!!!!

        if ($typehash{$objname} eq 'site')
        {
            my @TableRowArray = xCAT::DBobjUtils->getDBtable('site');

            if (defined(@TableRowArray))
            {
                my $foundinfo = 0;
                foreach (@TableRowArray)
                {

                    if ($_->{key})
                    {
						if (defined($_->{value}) ) {
                        	$foundinfo++;
							if ($::VERBOSE) {
								$objhash{$objname}{$_->{key}} = "$_->{value}\t(Table:site - Key:$_->{key})";
							} else {
                        		$objhash{$objname}{$_->{key}} = $_->{value};
							}
						}
                    }
                }
                if ($foundinfo)
                {
                    $objhash{$objname}{'objtype'} = 'site';
                }
            }
            else
            {
				 my $rsp;
                 $rsp->{data}->[0] ="Could not read the \'$objname\' object from the \'site\' table.\n";
                 xCAT::MsgUtils->message("E", $rsp, $::callback);	
            }
            next;
        }

        # get data from DB
        my $type = $typehash{$objname};

        # add the type to the hash for each object
        $objhash{$objname}{'objtype'} = $type;

        # get the object type decription from Schema.pm
        my $datatype = $xCAT::Schema::defspec{$type};

        # get the key to look for, for this object type
        my $objkey = $datatype->{'objkey'};

        #  get a list of valid attr names
        #       for this type object
		my %attrlist;
        foreach my $entry (@{$datatype->{'attrs'}})
        {
            push(@{$attrlist{$type}}, $entry->{'attr_name'});
        }

        # go through the list of valid attrs
        foreach my $this_attr (@{$datatype->{'attrs'}})
        {
            my $ent;

            my $attr = $this_attr->{attr_name};

            # skip the key attr  ???
			if ($attr eq $objkey)
            {
                next;
            }

            # get table lookup info from Schema.pm
            #  !!!! some tables depend on the value of certain attrs
            #   we need to look up attrs in the correct order or we will
            #   not be able to determine what tables to look
            #	in for some attrs.

            if (exists($this_attr->{only_if}))
            {
                my ($check_attr, $check_value) = split('\=', $this_attr->{only_if});

                # if the object value is not the value we need
                #   to match then try the next only_if value
				next if ( !($objhash{$objname}{$check_attr} =~ /\b$check_value\b/) );
            }

            #  OK - get the info needed to access the DB table
            #   - i.e. table name, key name, attr names

            # need the actual table attr name corresponding
            #   to the object attr name
            #  ex. noderes.nfsdir
            my ($tab, $tabattr) = split('\.', $this_attr->{tabentry});

            # ex. 'nodelist.node', 'attr:node'
            my ($lookup_key, $lookup_value) = split('\=', $this_attr->{access_tabentry});

            # ex. 'nodelist', 'node'
            my ($lookup_table, $lookup_attr) = split('\.', $lookup_key);

            # ex. 'attr', 'node'
            my ($lookup_type, $lookup_data) = split('\:', $lookup_value);

            #
            # Get the attr values 
            #

			# lookup_attr is the key to the table we are looking in
			# if we're looking up a node attr and the key is 'node'
			#	then the value should be in %tabhash
			if ( ($lookup_attr eq 'node') && ($type eq 'node') )
            {
				if (defined($tabhash{$lookup_table}{$objname}{$tabattr}) ) {
					if ($::VERBOSE) {
						$objhash{$objname}{$attr} = "$tabhash{$lookup_table}{$objname}{$tabattr}\t(Table:$lookup_table - Key:$tabattr)";
					} else {
						$objhash{$objname}{$attr} = $tabhash{$lookup_table}{$objname}{$tabattr};
					}
				}

			}
            else
            {
                # look up attr values
                my @rows = xCAT::DBobjUtils->getDBtable($lookup_table);
                if (defined(@rows))
                {
                    foreach (@rows)
                    {
                        if ($_->{$lookup_attr} eq $objname)
                        {
							if (defined($_->{$tabattr}) ) {
								if ($::VERBOSE) {
									$objhash{$objname}{$attr} = "$_->{$tabattr}\t(Table:$lookup_table - Key:$tabattr)";
								} else {
                           			$objhash{$objname}{$attr} = $_->{$tabattr};
								}
							}
                        }
                    }
                }
                else
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                          "Could not read the \'$lookup_table\' table from the xCAT database.";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return undef;
                }

            }
        }

		if ($typehash{$objname} eq 'monitoring') {
		
        	# need a special case for the monitoring table
			# 	- need to check the monsetting table for entries that contain
			#	 the same name as the monitoring table entry.

        	my @TableRowArray = xCAT::DBobjUtils->getDBtable('monsetting');

        	if (defined(@TableRowArray))
            {
                my $foundinfo = 0;
                foreach (@TableRowArray)
                {

					if ($_->{name} eq $objname ) {

                    	if ($_->{key})
                    	{
                        	$foundinfo++;
							if (defined($_->{value}) ) {
								$foundinfo++;
								if ($::VERBOSE) {
									$objhash{$objname}{$_->{key}} = "$_->{value}\t(Table:monsetting - Key:$_->{key})";
								} else {
                        			$objhash{$objname}{$_->{key}} = $_->{value};
								}
							}
                    	}
					}
                }
                if ($foundinfo)
                {
                    $objhash{$objname}{'objtype'} = 'monitoring';
                }
            }
            else
            {
				 my $rsp;
                 $rsp->{data}->[0] ="Could not read the \'$objname\' object from the \'monsetting\' table.\n";
                 xCAT::MsgUtils->message("E", $rsp, $::callback);	
            }
            next;

		}
    }
    return %objhash;
}

#----------------------------------------------------------------------------

=head3   getDBtable

        Get a DB table, cache it , & return list of rows from the table.

        Arguments:
        Returns:
                undef - error
                @rows - of table
        Globals:
        Error:
        Example:

        call as follows
          my @TableRowArray= xCAT::DBobjUtils->getDBtable($tablename); 

        Comments:

=cut

#-----------------------------------------------------------------------------
sub getDBtable
{
    my ($class, $table) = @_;
    my @rows = [];

	# save this table info - in case this subr gets called multiple times
    if (grep(/^$table$/, @::foundTableList))
    {

        # already have this
        @rows = @{$::TableHash{$table}};

    }
    else
    {

    	# need to get info from DB
    	my $thistable = xCAT::Table->new($table, -create => 1, -autocommit => 0);
    	if (!$thistable)
    	{
        	return undef;
    	}

    	@rows = $thistable->getTable;

    	#   !!!! this routine returns rows even if the table is empty!!!!!!

		#  keep track of the fact that we checked this table
        #   - even if it's empty!
        push(@::foundTableList, $thistable->{tabname});

        @{$::TableHash{$table}} = @rows;

    	$thistable->commit;

	} # end if not cached

   	if (defined(@rows))
   	{
       	return @rows;
   	}
   	else
   	{
       	return undef;
    }
}

#----------------------------------------------------------------------------

=head3   setobjdefs

        Set the object definitions in the DB.
            - Handles the Schema lookup and updating the DB tables.

        Arguments:
        Returns:
                1 - error
                0 - OK
        Globals:
        Error:
        Example:

        To use:
		 	-create hash for objectname and object type
            	ex. $objhash{$object}{$attribute} = value;

			-then call as follows:
				if (xCAT::DBobjUtils->setobjdefs(\%objhash) != 0)

        Comments:

=cut

#-----------------------------------------------------------------------------
sub setobjdefs
{
    my ($class, $hash_ref) = @_;
    my %objhash = %$hash_ref;
    my %settableref;
    my $ret = 0;

    foreach my $objname (keys %objhash)
    {

        # get attr=val that are set in the DB ??
        my $type = $objhash{$objname}{objtype};

		# handle the monitoring table as a special case !!!!!
        if ($type eq 'monitoring')
        {

			my %DBattrvals;
			# if plus or minus then need to know current settings
			if ( ($::plus_option) || ($::minus_option) ) {
            	my %DBhash;
            	$DBhash{$objname} = $type;
            	%DBattrvals = xCAT::DBobjUtils->getobjdefs(\%DBhash);
			}

			# Get the names of the attrs stored in monitoring table
			# get the object type decription from Schema.pm
        	my $datatype = $xCAT::Schema::defspec{$type};

        	#  get a list of valid attr names
        	#               for this type object
        	my @attrlist;
        	foreach my $entry (@{$datatype->{'attrs'}})
        	{
            	push(@attrlist, $entry->{'attr_name'});
        	}

			# open the tables (monitoring and monsetting)
            my $montable = xCAT::Table->new('monitoring', -create => 1, -autocommit => 0);
            if (!$montable)
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not set the \'$montable\' table.";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }
			# open the table
            my $monsettable = xCAT::Table->new('monsetting', -create => 1, -autocommit => 0);
            if (!$monsettable)
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not set the \'$monsettable\' table.";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }

			my %keyhash; 
			my %updates;

			foreach my $attr (keys %{$objhash{$objname}})
            {
				my $val;
                if ($attr eq 'objtype')
                {
                    next;
                }

				# determine the value if we have plus or minus
				if ($::plus_option)
                {
                    # add new to existing - at the end - comma separated
                    if (defined($DBattrvals{$objname}{$attr}))
                    {
                        $val =
                          "$DBattrvals{$objname}{$attr},$objhash{$objname}{$attr}";
                    }
                    else
                    {
                        $val = "$objhash{$objname}{$attr}";
                    }
                }
                elsif ($::minus_option)
				{
                    # remove the specified list of values from the current
                    #   attr values.
                    if ($DBattrvals{$objname}{$attr})
                    {
                        # get the list of attrs to remove
                        my @currentList = split(/,/, $DBattrvals{$objname}{$attr});
                        my @minusList   = split(/,/, $objhash{$objname}{$attr});

                        # make a new list without the one specified
                        my $first = 1;
                        my $newlist;
                        foreach my $i (sort @currentList)
                        {
                            chomp $i;
                            if (!grep(/^$i$/, @minusList))
                            {
                                # set new groups list for node
                                if (!$first)
                                {
                                    $newlist .= ",";
                                }
                                $newlist .= $i;
                                $first = 0;
                            }
                        }
                        $val = $newlist;
                    }
                }
                else
                {
                    #just set the attr to what was provided! - replace
                    $val = $objhash{$objname}{$attr};
                }

				if (grep(/^$attr$/, @attrlist)) {
					# if the attr belong in the monitoring tabel
					%keyhash=(name=>$objname);
					%updates=($attr=>$val);
					$montable->setAttribs(\%keyhash, \%updates);

				} else {
					# else it belongs in the monsetting table
					$keyhash{name} = $objname;
					$keyhash{key} = $attr;
                	$updates{value} = $val;
					$monsettable->setAttribs(\%keyhash, \%updates);
				}
			}

			$montable->commit;
			$monsettable->commit;

			next;
		}

        # handle the site table as a special case !!!!!
        if ($type eq 'site')
        {

            # if plus or minus then need to know current settings
            my %DBhash;
            $DBhash{$objname} = $type;
            my %DBattrvals;
            %DBattrvals = xCAT::DBobjUtils->getobjdefs(\%DBhash);

            # open the table
            my $thistable =
              xCAT::Table->new('site', -create => 1, -autocommit => 0);
            if (!$thistable)
            {
                my $rsp;
                $rsp->{data}->[0] = "Could not set the \'$thistable\' table.";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }

            foreach my $attr (keys %{$objhash{$objname}})
            {
                if ($attr eq 'objtype')
                {
                    next;
                }

				my %keyhash;
                $keyhash{key} = $attr;

                my $val;
                if ($::plus_option)
                {

                    # add new to existing - at the end - comma separated
                    if (defined($DBattrvals{$objname}{$attr}))
                    {
                        $val =
                          "$DBattrvals{$objname}{$attr},$objhash{$objname}{$attr}";
                    }
                    else
                    {
                        $val = "$objhash{$objname}{$attr}";
                    }

                }
                elsif ($::minus_option)
                {

                    # remove the specified list of values from the current
                    #   attr values.
                    if ($DBattrvals{$objname}{$attr})
                    {

                        # get the list of attrs to remove
                        my @currentList = split(/,/, $DBattrvals{$objname}{$attr});
                        my @minusList   = split(/,/, $objhash{$objname}{$attr});

                        # make a new list without the one specified
                        my $first = 1;
                        my $newlist;
                        foreach my $i (sort @currentList)
                        {
                            chomp $i;
                            if (!grep(/^$i$/, @minusList))
                            {

                                # set new groups list for node
                                if (!$first)
                                {
                                    $newlist .= ",";
                                }
                                $newlist .= $i;
                                $first = 0;
                            }
                        }
                        $val = $newlist;
                    }

                }
                else
                {

                    #just set the attr to what was provided! - replace
                    $val = $objhash{$objname}{$attr};

                }

				if ( $val eq "") { # delete the line

					$thistable->delEntries(\%keyhash);

				}  else { # change the attr

					my %updates;
                	$updates{value} = $val;

                	my ($rc, $str) = $thistable->setAttribs(\%keyhash, \%updates);
                	if (!defined($rc))
                	{
                    	if ($::verbose)
                    	{
                        	my $rsp;
                        	$rsp->{data}->[0] =
                          	"Could not set the \'$attr\' attribute of the \'$objname\' object in the xCAT database.\n";
                        	$rsp->{data}->[1] =
                          	"Error returned is \'$str->errstr\'.";
                        	xCAT::MsgUtils->message("I", $rsp, $::callback);
                    	}
                    	$ret = 1;
                	}
				}

            }

            $thistable->commit;

            next;
        }

        # get the attr=vals for these objects from the DB - if any
        #       - so we can figure out where to put additional attrs
        my %DBhash;
        $DBhash{$objname} = $type;

        my %DBattrvals;

        %DBattrvals = xCAT::DBobjUtils->getobjdefs(\%DBhash);

        # get the object type decription from Schema.pm
        my $datatype = $xCAT::Schema::defspec{$type};

		# get the key to look for, for this object type
        my $objkey = $datatype->{'objkey'};

        #  get a list of valid attr names
        #               for this type object
        my %attrlist;
        foreach my $entry (@{$datatype->{'attrs'}})
        {
            push(@{$attrlist{$type}}, $entry->{'attr_name'});
        }

		my @attrprovided=();

        # check FINALATTRS to see if all the attrs are valid
        foreach my $attr (keys %{$objhash{$objname}})
        {

		if ($attr eq $objkey)
		{
			next;
		}

            if ($attr eq "objtype")
            {

                # objtype not stored in object definition
                next;
            }

            if (!(grep /^$attr$/, @{$attrlist{$type}}))
            {
                if ($::verbose)
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "\'$attr\' is not a valid attribute for type \'$type\'.";
                    $rsp->{data}->[1] = "Skipping to the next attribute.";
                    xCAT::MsgUtils->message("I", $rsp, $::callback);
                }
                next;
            }
			push(@attrprovided, $attr); 

        }

        #   we need to figure out what table to
        #               store each attr
        #   And we must do this in the order given in defspec!!


		my @setattrlist=();
		my @checkedattrs;

        foreach my $this_attr (@{$datatype->{'attrs'}})
        {

            my %keyhash;
            my %updates;
			my ($lookup_table, $lookup_attr);
            my $attr_name = $this_attr->{attr_name};

			if ($attr_name eq $objkey)
			{
    			next;
			}

            # if we have a value for this attribute then process it
            #   - otherwise go to the next attr
            if (defined($objhash{$objname}{$attr_name}))
            {

                # check the defspec to see where this attr goes

                # the table for this attr might depend on the
                #       value of some other attr
                # need to check the only_if entries to find one where the
                #       other attr value matches what we have
                #       ex. like if I want to set hdwctrlpoint I will have
                #               to match the right value for mgtmethod
                if (exists($this_attr->{only_if}))
                {
                    my ($check_attr, $check_value) =
                      split('\=', $this_attr->{only_if});

                    # if my attr value for the attr to check doesn't
                    #   match this then try the next one
                    # ex. say I want to set hdwctrlpoint, the table
                    #   will depend on the mgtmethod attr - so I need
                    #   to find the 'only_if' that matches the value
                    #   specified for that attr (ex. mgtmethod=hmc)

                    # need to check the attrs we are setting for the object
                    #   as well as the attrs for this object that may be
                   	#   already set in DB

					if ( !($objhash{$objname}{$check_attr})  && !($DBattrvals{$objname}{$check_attr}) ) {
                        # if I didn't already check for this attr
                        # if ($::VERBOSE) {
                        my $rsp;
                        if (!grep(/^$attr_name$/, @checkedattrs)) {
                            push @{$rsp->{data}}, "Cannot set the \'$attr_name\' attribute unless a value is provided for \'$check_attr\'.\n";

                            foreach my $tmp_attr (@{$datatype->{'attrs'}}) {
                                my $attr = $tmp_attr->{attr_name};
                                if ($attr eq $check_attr) {
                                    my ($tab, $at) = split(/\./, $tmp_attr->{tabentry});
                                    my $schema = xCAT::Table->getTableSchema($tab);
                                    my $desc = $schema->{descriptions}->{$at};
                                    push @{$rsp->{data}}, "$check_attr => $desc\n";
                                }
                            }
                        }
						xCAT::MsgUtils->message("I", $rsp, $::callback);
                       # }
						push(@checkedattrs, $attr_name);
                        next;
                    }

					if ( !($objhash{$objname}{$check_attr} =~ /\b$check_value\b/) && !($DBattrvals{$objname}{$check_attr}  =~ /\b$check_value\b/) )
                    {
                        next;

                    }
                }

                #  get the info needed to write to the DB table
                #
                # get the actual attr name to use in the table
                #    - may be different then the attr name used for the object.
                ($::tab, $::tabattr) = split('\.', $this_attr->{tabentry});

                # get the lookup info from defspec in Schema.pm
                # ex. 'nodelist.node', 'attr:node'
                my ($lookup_key, $lookup_value) =
                  split('\=', $this_attr->{access_tabentry});

                # ex. 'nodelist', 'node'
                ($lookup_table, $lookup_attr) = split('\.', $lookup_key);

                # ex. 'attr', 'node'
                my ($lookup_type, $lookup_data) = split('\:', $lookup_value);

            }
            else
            {
                next;
            }

            #
            # write to the DB table
            #

            my $thistable;
            my $needtocommit = 0;

            # ex. node= c68m3hvp03 (key in table)
            $keyhash{$lookup_attr} = $objname;

            my $val;
            if ($::plus_option)
            {

                # add new to existing - at the end - comma separated
                if (defined($DBattrvals{$objname}{$attr_name}))
                {
					# if it's not already in the list!
					if (!($DBattrvals{$objname}{$attr_name} =~ /\b$objhash{$objname}{$attr_name}\b/) )
					{
                    	$val = "$DBattrvals{$objname}{$attr_name},$objhash{$objname}{$attr_name}";
					} else {
						$val = "$DBattrvals{$objname}{$attr_name}";
					}
                }
                else
                {
                    $val = "$objhash{$objname}{$attr_name}";
                }

            }
            elsif ($::minus_option)
            {

                # remove the specified list of values from the current
                #	attr values.
                if ($DBattrvals{$objname}{$attr_name})
                {

                    # get the list of attrs to remove
                    my @currentList =
                      split(/,/, $DBattrvals{$objname}{$attr_name});
                    my @minusList = split(/,/, $objhash{$objname}{$attr_name});

                    # make a new list without the one specified
                    my $first = 1;
                    my $newlist;
                    foreach my $i (sort @currentList)
                    {
                        chomp $i;
                        if (!grep(/^$i$/, @minusList))
                        {

                            # set new list for node
                            if (!$first)
                            {
                                $newlist .= ",";
                            }
                            $newlist .= $i;
                            $first = 0;
                        }
                    }
                    $val = $newlist;
                }

            }
            else
            {

                #just set the attr to what was provided! - replace
                $val = $objhash{$objname}{$attr_name};

            }

            # ex. nodetype = osi (attr=val or col = col value)
            $updates{$::tabattr} = "$val";

            if (ref($::settableref{$lookup_table}))
            {

                # if we already opened this table use the reference
                $thistable = $::settableref{$lookup_table};
            }
            else
            {

                # open the table
                $thistable =
                  xCAT::Table->new(
                                   $lookup_table,
                                   -create     => 1,
                                   -autocommit => 0
                                   );

                if (!$thistable)
                {
                    my $rsp;
                    $rsp->{data}->[0] =
                      "Could not set the \'$thistable\' table.";
                    xCAT::MsgUtils->message("E", $rsp, $::callback);
                    return 1;
                }

                # set the attr values in the DB
                my ($rc, $str) = $thistable->setAttribs(\%keyhash, \%updates);
                if (!defined($rc))
                {
                    if ($::verbose)
                    {
                        my $rsp;
                        $rsp->{data}->[0] =
                          "Could not set the \'$attr_name\' attribute of the \'$objname\' object in the xCAT database.\n";
                        $rsp->{data}->[1] = "Error returned is \'$str->errst
r\'.";
                        xCAT::MsgUtils->message("I", $rsp, $::callback);
                    }
                    $ret = 1;
					$thistable->commit;
                    next;
                }

                # $::settableref{$lookup_table} = $thistable;
				
				push(@setattrlist, $attr_name);

                $thistable->commit;

            }

        }    # end - foreach attribute

		#
		#  check to see if all the attrs got set
		#
		# debug: print "attrprovided = @attrprovided, setattrlist = @setattrlist\n";

		my @errlist;
		foreach $a (@attrprovided)
        {	
			#  is this attr was not set then add it to the error list
			if (!grep(/^$a$/, @setattrlist))
			{			
				push(@errlist, $a);
				$ret = 2;
			}

		}
		if ($ret == 2) {
			my $rsp;
			$rsp->{data}->[0] = "Could not set the following attributes for the \'$objname\' definition in the xCAT database: \'@errlist\'\n";
			xCAT::MsgUtils->message("E", $rsp, $::callback);
		}

    }    # end - foreach object

    return $ret;
}

#----------------------------------------------------------------------------

=head3   rmobjdefs

        Remove object definitions from the DB.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Error:
        Example:

		To use create hash for object name and object type
            ex. $objhash{$obj} = $type;
        - then call as follows:
			xCAT::DBobjUtils->rmobjdefs(\%objhash);

        Comments:

=cut

#-----------------------------------------------------------------------------
sub rmobjdefs
{
    my ($class, $hash_ref) = @_;

    my %tablehash;

    my %typehash = %$hash_ref;

    # get the attr=vals for these objects so we know how to
    #   find what tables have to be modified
    my %DBattrvals = xCAT::DBobjUtils->getobjdefs(\%typehash);

	foreach my $objname (sort (keys %typehash))
    {
        my $type = $typehash{$objname};

        # special handling for site table
        if ($type eq 'site')
        {
            my $thistable =
              xCAT::Table->new('site', -create => 1, -autocommit => 0);
            my %keyhash;
            foreach my $attr (keys %{$DBattrvals{$objname}})
            {

                # ex.  key = attr
                $keyhash{key} = $attr;

                $thistable->delEntries(\%keyhash);

            }
            $thistable->commit();
            next;
        }

        # get the object type decription from Schema.pm
        my $datatype = $xCAT::Schema::defspec{$type};

        # go through the list of valid attrs
        #  - need to delete the row with a $key value of $objname from $table
        #  - make a hash containing $delhash{$table}{$key}= $objname
        foreach my $this_attr (@{$datatype->{'attrs'}})
        {
            my $attr = $this_attr->{attr_name};

            # get table lookup info from Schema.pm

            # might need to check the value of other attrs to figure out
            #   what tables some attrs are in
            if (exists($this_attr->{only_if}))
            {
                my ($check_attr, $check_value) =
                  split('\=', $this_attr->{only_if});

                # if the object attr value to check is not the value we need
                #   to match then try the next "only_if" value
                #   next if $DBattrvals{$objname}{$check_attr} ne $check_value;
				next if ( !($DBattrvals{$objname}{$check_attr} =~ /\b$check_value\b/) );

            }

            #  get the info needed to access the DB table
            # ex. 'nodelist.node', 'attr:node'
            my ($lookup_key, $lookup_value) =
              split('\=', $this_attr->{access_tabentry});

            # ex. 'nodelist', 'node'
            my ($lookup_table, $lookup_attr) = split('\.', $lookup_key);

            # ex. 'attr', 'node'
            my ($lookup_type, $lookup_data) = split('\:', $lookup_value);

            # we'll need table name, key name, & object name
            # put this info in a hash - we'll process it later - below

            push @{$tablehash{$lookup_table}{$lookup_attr}}, $objname;
        }
    }

    # now for each table - clear the entry
    foreach my $table (keys %tablehash)
    {
        my %keyhash;

        my $thistable =
          xCAT::Table->new($table, -create => 1, -autocommit => 0);

        #  some tables have multiple keys  !!??
        foreach my $key (keys %{$tablehash{$table}})
        {

            #  - may have a list of objects to remove from the table
            # ex. say key is "node" and table is "nodelist"
            foreach my $obj (@{$tablehash{$table}{$key}})
            {

                # ex. $keyhash{node}=c68m3hvp01
                $keyhash{$key} = $obj;

                # ex. delete the c68m3hvp01 entry of the node column in the
                #	nodelist table
                $thistable->delEntries(\%keyhash);
            }

        }

        $thistable->commit();
    }

    return 0;

}

#----------------------------------------------------------------------------

=head3   readFileInput

        Process the command line input piped in from a file.
		 	(Support stanza or xml format.)

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Error:
        Example:

        Comments:
			Set @::fileobjtypes, @::fileobjnames, %::FILEATTRS
				(i.e.- $::FILEATTRS{objname}{attr}=val)

=cut

#-----------------------------------------------------------------------------
sub readFileInput
{
    my ($class, $filedata) = @_;
	my ($objectname, $junk1, $junk2);

    @::fileobjnames = ();

    my @lines = split /\n/, $filedata;

    my $header = @lines[0];

    # to do
    #if ($header =~/<xCAT data object stanza file>/) {
    # do stanza file parsing
    # } elsis ($header =~/<xCAT data object XML file>/) {
    # do XML parsing
    #}

    my $look_for_colon = 1;    # start with first line that has a colon
	my $objtype;

    foreach my $l (@lines)
    {

        # skip blank and comment lines
        next if ($l =~ /^\s*$/ || $l =~ /^\s*#/);

        # see if it's a stanza name
        if (grep(/:\s*$/, $l))
        {

            $look_for_colon = 0;    # ok - we have a colon

            ($objectname, $junk2) = split(/:/, $l);

            # if $junk2 is defined or there's an = 
            if ($junk2 || grep(/=/, $objectname))
            {

                # error - invalid header $line in node definition file
                #         skipping to next node stanza
                # Skipping to the next valid header.
                $look_for_colon++;
                next;
            }

            $objectname =~ s/^\s*//;    # Remove any leading whitespace
            $objectname =~ s/\s*$//;    # Remove any trailing whitespace

            #  could have different default stanzas for different object types

            if ($objectname =~ /default/)
            {

                ($junk1, $objtype) = split(/-/, $objectname);

                if ($objtype)
                {
                    $objectname = 'default';
                }

                next;
            }

            push(@::fileobjnames, $objectname);

        }
        elsif (($l =~ /^\s*(\w+)\s*=\s*(.*)\s*/) && (!$look_for_colon))
        {
            my $attr = $1;
            my $val  = $2;
            $attr =~ s/^\s*//;    # Remove any leading whitespace
            $attr =~ s/\s*$//;    # Remove any trailing whitespace
            $val  =~ s/^\s*//;
            $val  =~ s/\s*$//;

            # remove spaces and quotes so createnode won't get upset
            $val =~ s/^\s*"\s*//;
            $val =~ s/\s*"\s*$//;

            if ($objectname eq "default")
            {

                # set the default for this attribute
                $::defAttrs{$objtype}{$attr} = $val;

            }
            else
            {

                # set the value in the hash for this object
                $::FILEATTRS{$objectname}{$attr} = $val;

                # if the attr being set is "objtype" then check
                # 	to see if we have any defaults set for this type
                # the objtype should be the first etntry in each stanza
                #	so after we set the defaults they will be overwritten
                #	by any values that appear in the rest of the stanza
                if ($attr eq 'objtype')
                {
                    push(@::fileobjtypes, $val);

                    #  $val will be the object type ex. site, node etc.
                    foreach my $a (keys %{$::defAttrs{$val}})
                    {

                        # set the default values for this object hash
                        $::FILEATTRS{$objectname}{$a} = $::defAttrs{$val}{$a};
                    }
                }
            }

        }
        else
        {

            # error - invalid line in node definition file
            $look_for_colon++;
        }

    }    # end while - go to next line

    return 0;

}

#----------------------------------------------------------------------------

=head3   getGroupMembers

        Get the list of members for the specified group.

        Arguments:
        Returns:
            undef - error
            $members - comma-separated list of group members
        Globals:
        Error:
        Example:
			To use:
            - create hash for objectname and and attr values  (need group 
				name (object), and grouptype  & members attr values at a
				minimum.)
			
                ex. $objhash{$obj}{$attr} = value;

            - then call as follows:
                xCAT::DBobjUtils->getGroupMembers($objectname, \%objhash);

        Comments:

=cut

#-----------------------------------------------------------------------------
sub getGroupMembers
{
    my ($class, $objectname, $hash_ref) = @_;

    my $members;

    my %objhash = %$hash_ref;

    if ($objhash{$objectname}{'grouptype'} eq 'static')
    {

        my $table = "nodelist";

        my @TableRowArray = xCAT::DBobjUtils->getDBtable($table);

        my $first = 1;
        foreach (@TableRowArray)
        {

            # if find the group name in the "groups" attr value then add the
            #	 node name to the member list
            #if ($_->{'groups'} =~ /$objectname/)

            my @nodeGroupList = split(',', $_->{'groups'});
            if (grep(/^$objectname$/, @nodeGroupList))

            {
                chomp($_->{'node'});
                if (!$first)
                {
                    $members .= ",";
                }
                $members .= $_->{'node'};
                $first = 0;
            }
        }

    }
    elsif ($objhash{$objectname}{'grouptype'} eq 'dynamic')
    {

        # find all nodes that satisfy the criteria specified in "wherevals"
        #	value
        my %whereHash;

        # remove spaces and quotes so createnode won't get upset
        #$val =~ s/^\s*"\s*//;
        #$val =~ s/\s*"\s*$//;

        my @tmpWhereList = split(',', $objhash{$objectname}{'wherevals'});
        foreach my $w (@tmpWhereList)
        {
            my ($a, $v) = $w =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($a) || !defined($v))
            {
                my $rsp;
                $rsp->{data}->[0] =
                  "The \'-w\' option has an incorrect attr=val pair - \'$w\'.";
                xCAT::MsgUtils->message("I", $rsp, $::callback);
                next;
            }

            $whereHash{$a} = $v;

        }

        # see what nodes have these attr=values
        # get a list of all nodes
        my @tmplist = xCAT::DBobjUtils->getObjectsOfType('node');

        # create a hash of obj names and types
		my %tmphash;
        foreach my $n (@tmplist)
        {
            $tmphash{$n} = 'node';
        }

        # get all the attrs for these nodes
        my %myhash = xCAT::DBobjUtils->getobjdefs(\%tmphash);

        my $first = 1;
        foreach my $objname (keys %myhash)
        {

            #  all the "where" attrs must match the object attrs
            my $addlist = 1;

            foreach my $testattr (keys %whereHash)
            {
                if ($myhash{$objname}{$testattr} ne $::WhereHash{$testattr})
                {

                    # don't disply
                    $addlist = 0;
                    next;
                }
            }
            if ($addlist)
            {
                chomp($objname);
                if (!$first)
                {
                    $members .= ",";
                }
                $members .= $objname;
                $first = 0;
            }
        }

    }
    return $members;
}

#----------------------------------------------------------------------------

=head3   getNetwkInfo

        Get the network info from the database for a list of nodes.

        Arguments:
        Returns:
                undef
                hash ref - ex. $nethash{nodename}{networks attr name} = value
        Globals:
        Error:
        Example:

                %nethash = xCAT::DBobjUtils->getNetwkInfo(\@targetnodes);

		Comments:
			      Not supporting IPv6 yet

=cut

#-----------------------------------------------------------------------------
sub getNetwkInfo
{
	my ($class, $ref_nodes) = @_;
	my @nodelist    = @$ref_nodes;

	my %nethash;
	my @attrnames;

	# get the current list of network attrs (networks table columns)
    my $datatype = $xCAT::Schema::defspec{'network'};
	foreach my $a (@{$datatype->{'attrs'}}) {
		my $attr = $a->{attr_name};
		push(@attrnames, $attr);
	}

	# read the networks table
	my @TableRowArray = xCAT::DBobjUtils->getDBtable('networks');
	if (!defined(@TableRowArray))
    {
		return undef;
	}

	# for each node - get the network info
	foreach my $node (@nodelist)
    {

		# get, check, split the node IP
		my $IP = inet_ntoa(inet_aton($node));
		chomp $IP;
		unless ($IP =~ /\d+\.\d+\.\d+\.\d+/)
		{
    		next;    #Not supporting IPv6 yet
		}
		my ($ia, $ib, $ic, $id) = split('\.', $IP);

		# check the entries of the networks table
		# - if the bitwise AND of the IP and the netmask gives you 
		#	the "net" name then that is the entry you want.
		foreach (@TableRowArray) {
			my $NM = $_->{'mask'};
			my $net=$_->{'net'};
			chomp $NM;
			chomp $net;
			my ($n1, $n2, $n3, $n4) = split('\.', $net);
			my ($na, $nb, $nc, $nd) = split('\.', $NM);

			# Convert to integers so the bitwise and (&) works correctly.
			int $ia;
			int $ib;
			int $ic;
			int $id;
			int $na;
			int $nb;
			int $nc;
			int $nd;
			my $sa     = ($ia & $na);
			my $sb     = ($ib & $nb);
			my $sc     = ($ic & $nc);
			my $sd     = ($id & $nd);

			# if all the octals match then we have the right network
			if ( ($n1 == $sa) && ($n2 ==$sb) && ($n3 == $sc) && ($n4 == $sd) ) {
				# fill in the hash - 
				foreach my $attr (@attrnames) {
					if ( defined($_->{$attr}) ) {
						$nethash{$node}{$attr} = $_->{$attr};
					}
				}
				next;
			}
		}

	} #end - for each node

	return %nethash;
}

1;
