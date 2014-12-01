--  GHDL Run Time (GRT) - FST generator.
--  Copyright (C) 2014 Tristan Gingold
--
--  GHDL is free software; you can redistribute it and/or modify it under
--  the terms of the GNU General Public License as published by the Free
--  Software Foundation; either version 2, or (at your option) any later
--  version.
--
--  GHDL is distributed in the hope that it will be useful, but WITHOUT ANY
--  WARRANTY; without even the implied warranty of MERCHANTABILITY or
--  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
--  for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with GCC; see the file COPYING.  If not, write to the Free
--  Software Foundation, 59 Temple Place - Suite 330, Boston, MA
--  02111-1307, USA.
--
--  As a special exception, if other files instantiate generics from this
--  unit, or you link this unit with other files to produce an executable,
--  this unit does not by itself cause the resulting executable to be
--  covered by the GNU General Public License. This exception does not
--  however invalidate any other reasons why the executable file might be
--  covered by the GNU Public License.
with Interfaces; use Interfaces;
with Interfaces.C;
with System; use System;
with Grt.Types; use Grt.Types;
with Grt.Fst_Api; use Grt.Fst_Api;
with Grt.Vcd; use Grt.Vcd;
with Grt.Avhpi; use Grt.Avhpi;
with System.Storage_Elements; --  Work around GNAT bug.
pragma Unreferenced (System.Storage_Elements);
with Grt.Errors; use Grt.Errors;
with Grt.Signals; use Grt.Signals;
with Grt.Table;
with Grt.Astdio; use Grt.Astdio;
with Grt.Hooks; use Grt.Hooks;
with Grt.Rtis; use Grt.Rtis;
with Grt.Rtis_Types; use Grt.Rtis_Types;
with Grt.Vstrings;
pragma Elaborate_All (Grt.Table);

package body Grt.Fst is
   Context : fstContext := Null_fstContext;

   --  Index type of the table of vcd variables to dump.
   type Fst_Index_Type is new Integer;

   --  Return TRUE if OPT is an option for FST.
   function Fst_Option (Opt : String) return Boolean
   is
      F : constant Natural := Opt'First;
      Fst_Filename : String_Access;
   begin
      if Opt'Length < 6 or else Opt (F .. F + 5) /= "--fst=" then
         return False;
      end if;
      if Context /= Null_fstContext then
         Error ("--fst: file already set");
         return True;
      end if;

      --  Add an extra NUL character.
      Fst_Filename := new String (1 .. Opt'Length - 6 + 1);
      Fst_Filename (1 .. Opt'Length - 6) := Opt (F + 6 .. Opt'Last);
      Fst_Filename (Fst_Filename'Last) := NUL;

      Context := fstWriterCreate
        (To_Ghdl_C_String (Fst_Filename.all'Address), 1);
      if Context = Null_fstContext then
         Error_C ("fst: cannot open ");
         Error_E (Fst_Filename (Fst_Filename'First .. Fst_Filename'Last - 1));
      end if;
      return True;
   end Fst_Option;

   procedure Fst_Help is
   begin
      Put_Line (" --fst=FILENAME     dump signal values into an FST file");
   end Fst_Help;

   --  Called before elaboration.
   procedure Fst_Init
   is
      Version : constant String := "GHDL FST v0" & NUL;
   begin
      if Context = Null_fstContext then
         return;
      end if;

      fstWriterSetFileType (Context, FST_FT_VHDL);
      fstWriterSetPackType (Context, FST_WR_PT_LZ4);
      fstWriterSetTimescale (Context, -15); --  fs
      fstWriterSetVersion (Context, To_Ghdl_C_String (Version'Address));
      fstWriterSetRepackOnClose (Context, 1);
      fstWriterSetParallelMode (Context, 0);
   end Fst_Init;

   type Fst_Sig_Info is record
      Wire : Verilog_Wire_Info;
      Hand : fstHandle;
   end record;

   package Fst_Table is new Grt.Table
     (Table_Component_Type => Fst_Sig_Info,
      Table_Index_Type => Fst_Index_Type,
      Table_Low_Bound => 0,
      Table_Initial => 32);

   procedure Avhpi_Error (Err : AvhpiErrorT)
   is
      pragma Unreferenced (Err);
   begin
      Put_Line ("Fst.Avhpi_Error!");
   end Avhpi_Error;

   procedure Fst_Add_Signal (Sig : VhpiHandleT)
   is
      Vcd_El : Verilog_Wire_Info;
      Vt : fstVarType;
      Sdt : fstSupplementalDataType;
      Dir : fstVarDir;
      Len : Interfaces.C.unsigned;
      Name : String (1 .. 128);
      Name_Len : Natural;
      Hand : fstHandle;
   begin
      Get_Verilog_Wire (Sig, Vcd_El);

      case Vcd_El.Kind is
         when Vcd_Bad =>
            --  Not handled.
            return;
         when Vcd_Bool =>
            Vt := FST_VT_VCD_REG;
            Len := 1;
            Sdt := FST_SDT_VHDL_BOOLEAN;
         when Vcd_Integer32 =>
            Vt := FST_VT_VCD_INTEGER;
            Len := 1;
            Sdt := FST_SDT_VHDL_INTEGER;
         when Vcd_Float64 =>
            Vt := FST_VT_VCD_REAL;
            Len := 1;
            Sdt := FST_SDT_VHDL_REAL;
         when Vcd_Bit =>
            Vt := FST_VT_VCD_REG;
            Len := 1;
            Sdt := FST_SDT_VHDL_BIT;
         when Vcd_Stdlogic =>
            Vt := FST_VT_VCD_REG;
            Len := 1;
            Sdt := FST_SDT_VHDL_STD_LOGIC;
         when Vcd_Bitvector =>
            Vt := FST_VT_VCD_REG;
            Len := Interfaces.C.unsigned (Vcd_El.Irange.I32.Len);
            Sdt := FST_SDT_VHDL_BIT_VECTOR;
         when Vcd_Stdlogic_Vector =>
            Vt := FST_VT_VCD_REG;
            Len := Interfaces.C.unsigned (Vcd_El.Irange.I32.Len);
            Sdt := FST_SDT_VHDL_STD_LOGIC_VECTOR;
      end case;

      if Vhpi_Get_Kind (Sig) = VhpiPortDeclK then
         case Vhpi_Get_Mode (Sig) is
            when VhpiInMode =>
               Dir := FST_VD_INPUT;
            when VhpiInoutMode =>
               Dir := FST_VD_INOUT;
            when VhpiBufferMode =>
               Dir := FST_VD_BUFFER;
            when VhpiLinkageMode =>
               Dir := FST_VD_LINKAGE;
            when VhpiOutMode =>
               Dir := FST_VD_OUTPUT;
            when VhpiErrorMode =>
               Dir := FST_VD_IMPLICIT;
         end case;
      else
         Dir := FST_VD_IMPLICIT;
      end if;

      Vhpi_Get_Str (VhpiNameP, Sig, Name, Name_Len);
      if Name_Len >= Name'Length
        or else Vcd_El.Irange /= null
      then
         declare
            Name2 : String (1 .. Name_Len + 3 + 2 * 11 + 1);

            procedure Append (N : Ghdl_I32)
            is
               Num : String (1 .. 11);
               Num_First : Natural;
               Num_Len : Natural;
            begin
               Grt.Vstrings.To_String (Num, Num_First, N);
               Num_Len := Num'Last - Num_First + 1;
               Name2 (Name_Len + 1 .. Name_Len + Num_Len) :=
                 Num (Num_First .. Num'Last);
               Name_Len := Name_Len + Num_Len;
            end Append;
         begin
            Vhpi_Get_Str (VhpiNameP, Sig, Name2, Name_Len);
            if Vcd_El.Irange /= null then
               Name2 (Name_Len + 1) := '[';
               Name_Len := Name_Len + 1;
               Append (Vcd_El.Irange.I32.Left);
               Name2 (Name_Len + 1) := ':';
               Name_Len := Name_Len + 1;
               Append (Vcd_El.Irange.I32.Right);
               Name2 (Name_Len + 1) := ']';
               Name_Len := Name_Len + 1;
            end if;
            Name2 (Name_Len + 1) := NUL;
            Name_Len := Name_Len + 1;

            Hand := fstWriterCreateVar2
              (Context, Vt, Dir, Len, To_Ghdl_C_String (Name2'Address),
               Null_fstHandle, null, FST_SVT_VHDL_SIGNAL, Sdt);
         end;
      else
         Name (Name_Len) := NUL;
         Hand := fstWriterCreateVar2
           (Context, Vt, Dir, Len, To_Ghdl_C_String (Name'Address),
            Null_fstHandle, null, FST_SVT_VHDL_SIGNAL, Sdt);
      end if;

      Fst_Table.Append (Fst_Sig_Info'(Wire => Vcd_El, Hand => Hand));
   end Fst_Add_Signal;

   procedure Fst_Put_Hierarchy (Inst : VhpiHandleT);

   procedure Fst_Put_Scope (Scope : fstScopeType; Decl : VhpiHandleT)
   is
      Name : String (1 .. 128);
      Name_Len : Integer;
   begin
      Vhpi_Get_Str (VhpiNameP, Decl, Name, Name_Len);
      if Name_Len < Name'Last then
         Name (Name_Len + 1) := NUL;
      else
         --  Truncate
         Name (Name'Last) := NUL;
      end if;

      fstWriterSetScope
        (Context, Scope, To_Ghdl_C_String (Name'Address), null);
      Fst_Put_Hierarchy (Decl);
      fstWriterSetUpscope (Context);
   end Fst_Put_Scope;

   procedure Fst_Put_Hierarchy (Inst : VhpiHandleT)
   is
      Decl_It : VhpiHandleT;
      Decl : VhpiHandleT;
      Error : AvhpiErrorT;
   begin
      Vhpi_Iterator (VhpiDecls, Inst, Decl_It, Error);
      if Error /= AvhpiErrorOk then
         Avhpi_Error (Error);
         return;
      end if;

      --  Extract signals.
      loop
         Vhpi_Scan (Decl_It, Decl, Error);
         exit when Error = AvhpiErrorIteratorEnd;
         if Error /= AvhpiErrorOk then
            Avhpi_Error (Error);
            return;
         end if;

         case Vhpi_Get_Kind (Decl) is
            when VhpiPortDeclK
              | VhpiSigDeclK =>
               Fst_Add_Signal (Decl);
            when others =>
               null;
         end case;
      end loop;

      --  Extract sub-scopes.
      Vhpi_Iterator (VhpiInternalRegions, Inst, Decl_It, Error);
      if Error /= AvhpiErrorOk then
         Avhpi_Error (Error);
         return;
      end if;

      loop
         Vhpi_Scan (Decl_It, Decl, Error);
         exit when Error = AvhpiErrorIteratorEnd;
         if Error /= AvhpiErrorOk then
            Avhpi_Error (Error);
            return;
         end if;

         case Vhpi_Get_Kind (Decl) is
            when VhpiIfGenerateK =>
               Fst_Put_Scope (FST_ST_VHDL_IF_GENERATE, Decl);
            when VhpiForGenerateK =>
               Fst_Put_Scope (FST_ST_VHDL_FOR_GENERATE, Decl);
            when  VhpiBlockStmtK =>
               Fst_Put_Scope (FST_ST_VHDL_BLOCK, Decl);
            when VhpiCompInstStmtK =>
               Fst_Put_Scope (FST_ST_VHDL_ARCHITECTURE, Decl);
            when others =>
               null;
         end case;
      end loop;
   end Fst_Put_Hierarchy;

   procedure Fst_Put_Integer32 (Hand : fstHandle; V : Ghdl_U32)
   is
      Str : String (1 .. 32);
      Val : Ghdl_U32;
   begin
      Val := V;
      for I in Str'Range loop
         Str (I) := Character'Val (Character'Pos ('0') + (Val and 1));
         Val := Val / 2;
      end loop;
      fstWriterEmitValueChange (Context, Hand, Str'Address);
   end Fst_Put_Integer32;

   procedure Fst_Put_Var (I : Fst_Index_Type)
   is
      From_Bit : constant array (Ghdl_B1) of Character := "01";
      type Map_Type is array (Ghdl_E8 range 0 .. 8) of Character;
      From_Std : constant Map_Type := "UX01ZWLH-";
      V : Fst_Sig_Info renames Fst_Table.Table (I);
      Len : Ghdl_Index_Type;
      Hand : constant fstHandle := V.Hand;
      Sig : constant Signal_Arr_Ptr := V.Wire.Sigs;
   begin
      if V.Wire.Irange = null then
         Len := 1;
      else
         Len := V.Wire.Irange.I32.Len;
      end if;
      case V.Wire.Val is
         when Vcd_Effective =>
            case V.Wire.Kind is
               when Vcd_Bit
                 | Vcd_Bool
                 | Vcd_Bitvector =>
                  declare
                     Str : Std_String_Uncons (0 .. Len - 1);
                  begin
                     for I in Str'Range loop
                        Str (I) := From_Bit (Sig (I).Value.B1);
                     end loop;
                     fstWriterEmitValueChange (Context, Hand, Str'Address);
                  end;
               when Vcd_Stdlogic
                 | Vcd_Stdlogic_Vector =>
                  declare
                     Str : Std_String_Uncons (0 .. Len - 1);
                  begin
                     for I in Str'Range loop
                        Str (I) := From_Std (Sig (I).Value.E8);
                     end loop;
                     fstWriterEmitValueChange (Context, Hand, Str'Address);
                  end;
               when Vcd_Integer32 =>
                  Fst_Put_Integer32 (Hand, Sig (0).Value.E32);
               when Vcd_Float64 =>
                  null;
               when Vcd_Bad =>
                  null;
            end case;
         when Vcd_Driving =>
            case V.Wire.Kind is
               when Vcd_Bit
                 | Vcd_Bool
                 | Vcd_Bitvector =>
                  declare
                     Str : Std_String_Uncons (0 .. Len - 1);
                  begin
                     for I in Str'Range loop
                        Str (I) := From_Bit (Sig (I).Driving_Value.B1);
                     end loop;
                     fstWriterEmitValueChange (Context, Hand, Str'Address);
                  end;
               when Vcd_Stdlogic
                 | Vcd_Stdlogic_Vector =>
                  declare
                     Str : Std_String_Uncons (0 .. Len - 1);
                  begin
                     for I in Str'Range loop
                        Str (I) := From_Std (Sig (I).Driving_Value.E8);
                     end loop;
                     fstWriterEmitValueChange (Context, Hand, Str'Address);
                  end;
               when Vcd_Integer32 =>
                  Fst_Put_Integer32 (Hand, Sig (0).Driving_Value.E32);
               when Vcd_Float64 =>
                  null;
               when Vcd_Bad =>
                  null;
            end case;
      end case;
   end Fst_Put_Var;

   procedure Fst_Cycle;

   --  Called after elaboration.
   procedure Fst_Start
   is
      Root : VhpiHandleT;
   begin
      --  Do nothing if there is no VCD file to generate.
      if Context = Null_fstContext then
         return;
      end if;

      --  Be sure the RTI of std_ulogic is set.
      Search_Types_RTI;

      --  Put hierarchy.
      Get_Root_Inst (Root);
      Fst_Put_Hierarchy (Root);

      Register_Cycle_Hook (Fst_Cycle'Access);
   end Fst_Start;

   --  Called before each non delta cycle.
   procedure Fst_Cycle is
   begin
      --  Disp values.
      fstWriterEmitTimeChange (Context, Unsigned_64 (Cycle_Time));

      if Cycle_Time = 0 then
         --  Disp all values.
         for I in Fst_Table.First .. Fst_Table.Last loop
            Fst_Put_Var (I);
         end loop;
      else
         --  Disp only values changed.
         for I in Fst_Table.First .. Fst_Table.Last loop
            if Verilog_Wire_Changed (Fst_Table.Table (I).Wire, Cycle_Time) then
               Fst_Put_Var (I);
            end if;
         end loop;
      end if;
   end Fst_Cycle;

   --  Called at the end of the simulation.
   procedure Fst_End is
   begin
      if Context /= Null_fstContext then
         fstWriterClose (Context);
         Context := Null_fstContext;
      end if;
   end Fst_End;

   Fst_Hooks : aliased constant Hooks_Type :=
     (Option => Fst_Option'Access,
      Help => Fst_Help'Access,
      Init => Fst_Init'Access,
      Start => Fst_Start'Access,
      Finish => Fst_End'Access);

   procedure Register is
   begin
      Register_Hooks (Fst_Hooks'Access);
   end Register;
end Grt.Fst;