/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */
package net.sf.jftp.config;

import net.sf.jftp.gui.tasks.LastConnections;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;

/**
 * Clears FTP passwords already written by the removed Store passwords option.
 * Host, user, port, and directories stay in place.
 */
public final class StoredPasswordScrubber
{
    private StoredPasswordScrubber()
    {
    }

    public static void scrub()
    {
        blankSavedPasswordLine(Settings.login_def);
        blankSavedPasswordLine(Settings.login);
        blankSavedPasswordLine(Settings.login_def_sftp);
        blankSavedPasswordLine(Settings.login_def_smb);
        blankSavedPasswordLine(Settings.login_def_nfs);

        int index = 0;
        File numbered;

        while((numbered = new File(Settings.login + index)).isFile())
        {
            blankSavedPasswordLine(numbered.getPath());
            index++;
        }

        blankLastConnectionPasswords(Settings.last_cons);
    }

    /**
     * Saved-login files put the password on the third line.
     */
    private static void blankSavedPasswordLine(String path)
    {
        List<String> lines = readLines(path);

        if((lines == null) || (lines.size() < 3) || "".equals(lines.get(2)))
        {
            return;
        }

        lines.set(2, "");
        writeLines(path, lines);
    }

    /**
     * Recent-connection records are one field per line and end at
     * LastConnections.SENTINEL. The password is the fourth field.
     */
    private static void blankLastConnectionPasswords(String path)
    {
        List<String> lines = readLines(path);

        if(lines == null)
        {
            return;
        }

        int field = 0;
        boolean changed = false;

        for(int i = 0; i < lines.size(); i++)
        {
            String line = lines.get(i);

            if(line.equals(LastConnections.SENTINEL))
            {
                field = 0;

                continue;
            }

            if((field == 3) && !"".equals(line))
            {
                lines.set(i, "");
                changed = true;
            }

            field++;
        }

        if(changed)
        {
            writeLines(path, lines);
        }
    }

    private static List<String> readLines(String path)
    {
        File file = new File(path);

        if(!file.isFile())
        {
            return null;
        }

        List<String> lines = new ArrayList<String>();
        BufferedReader in = null;

        try
        {
            in = new BufferedReader(new FileReader(file));

            String line;

            while((line = in.readLine()) != null)
            {
                lines.add(line);
            }
        }
        catch(IOException ex)
        {
            return null;
        }
        finally
        {
            if(in != null)
            {
                try
                {
                    in.close();
                }
                catch(IOException ignored)
                {
                }
            }
        }

        return lines;
    }

    private static void writeLines(String path, List<String> lines)
    {
        PrintWriter out = null;

        try
        {
            out = new PrintWriter(path);

            for(int i = 0; i < lines.size(); i++)
            {
                out.println(lines.get(i));
            }
        }
        catch(IOException ex)
        {
            // Leave the existing file if it cannot be rewritten.
        }
        finally
        {
            if(out != null)
            {
                out.close();
            }
        }
    }
}
