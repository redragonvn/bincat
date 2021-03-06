(*
    This file is part of BinCAT.
    Copyright 2014-2017 - Airbus Group

    BinCAT is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or (at your
    option) any later version.

    BinCAT is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with BinCAT.  If not, see <http://www.gnu.org/licenses/>.
*)

(******************************************************************************)
(* Functor generating common functions of unrelational abstract domains       *)
(* basically it is a map from Registers/Memory cells to abstract values       *)
(******************************************************************************)

module L = Log.Make(struct let name = "unrel" end)

(** Unrelational domain signature *)
module type T =
  sig
    (** abstract data type *)
    type t
	   
    (** bottom value *)
    val bot: t
	       
    (** comparison to bottom *)
    val is_bot: t -> bool

    (** forgets the content but preserves the taint *)
    val forget: t -> t
      
    (** returns true whenever at least one bit of the parameter may be tainted. False otherwise *)
    val is_tainted: t -> bool
			   
    (** top value *)
    val top: t
	       
    (** conversion to values of type Z.t *)
    val to_z: t -> Z.t

    (** char conversion.
    May raise an exception if conversion fail (not a concrete value or too large) *)
    val to_char: t -> char
      
    (** converts a word into an abstract value *)
    val of_word: Data.Word.t -> t
				  
    (** comparison.
    Returns true whenever the concretization of the first parameter is included in the concretization of the second parameter *)
    val is_subset: t -> t -> bool
			    
    (** string conversion *)
    val to_string: t -> string

    (** return the taint and the value as a string separately *)
    val to_strings: t -> string * string
      
    (** value generation from configuration.
	The size of the value is given by the int parameter *)
    val of_config: Data.Address.region -> Config.cvalue -> int -> t
      
    (** returns the tainted value corresponding to the given abstract value.
    The size of the value is given by the int parameter *)
    val taint_of_config: Config.tvalue -> int -> t  -> t

      
    (** join two abstract values *)
    val join: t -> t -> t
			  
    (** meet the two abstract values *)
    val meet: t -> t -> t
			  
    (** widen the two abstract values *)
    val widen: t -> t -> t
			   
    (** [combine v1 v2 l u] computes v1[l, u] <- v2 *)
    val combine: t -> t -> int -> int -> t
					   
    (** converts an abstract value into a set of concrete adresses *)
    val to_addresses: t -> Data.Address.Set.t
			     
    (** [binary op v1 v2] return the result of v1 op v2 *)
    val binary: Asm.binop -> t -> t -> t
					 
    (** [unary op v] return the result of (op v) *)
    val unary: Asm.unop -> t -> t
				  
    (** binary comparison *)
    val compare: t -> Asm.cmp -> t -> bool
					
    (** [untaint v] untaint v *)
    val untaint: t -> t
			
    (** [taint v] taint v *)
    val taint: t -> t
		      
    (** [span_taint v t] span taint t on each bit of v *)
    val span_taint: t -> Tainting.t -> t

    (** returns the sub value between bits low and up *)
    val extract: t -> int -> int -> t
				      
    (** [from_position v p len] returns the sub value from bit p to bit p-len-1 *)
    val from_position: t -> int -> int -> t
					    
    (** [of_repeat_val val v_len nb] repeats provided pattern val having length v_len, nb times**)
    val of_repeat_val: t -> int -> int -> t
					    
    (** [concat [v1; v2 ; ... ; vn] ] returns value v such that v = v1 << |v2+...+vn| + v2 << |v3+...+vn| + ... + vn *)
    val concat: t list -> t

      (** returns the minimal taint value of the given parameter *)
      val get_minimal_taint: t -> Tainting.t
  end
    
    
module Make(D: T) =
  struct
    
   
			    
    (** type of the Map from Dimension (register or memory) to abstract values *)
    type t     =
      | Val of D.t Env.t (* For Ocaml non-gurus : Val is a Map, indexed by Key, with values of D.t *)
      | BOT

    type section = {
        virt_addr : Data.Address.t ;
        virt_size : Z.t ;
        raw_addr : Z.t ;
        raw_size : Z.t ;
        name : string }

    let sections_addr : section list ref = ref []
    type arrayt = ((int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Genarray.t)
    let mapped_file : arrayt option ref = ref None

    let bot = BOT
		
    let is_bot m = m = BOT
			 
    let value_of_register m r =
      match m with
      | BOT    -> raise Exceptions.Concretization
      | Val m' ->
         try
           let v = Env.find (Env.Key.Reg r) m' in D.to_z v
         with _ -> raise Exceptions.Concretization

    let string_of_register m r =
      match m with
      | BOT    -> raise Exceptions.Concretization
      | Val m' ->
	     let v = Env.find (Env.Key.Reg r) m' in D.to_string v
	     
    let add_register r m =
      let add x =
        Val (Env.add (Env.Key.Reg r) D.top x)
      in
      match m with
      | BOT    -> add Env.empty
      | Val m' -> add m'
		      
    let remove_register v m =
      L.debug (fun p -> p "remove_register(%s)" (Register.name v));
      match m with
      | Val m' -> Val (Env.remove (Env.Key.Reg v) m')
      | BOT    -> BOT
		    
		    
    let forget m =
      match m with
      | BOT -> BOT
      | Val m' -> Val (Env.map (fun _ -> D.top) m')
		      
    let forget_lval lv m =
      match m with
      | Val m' ->
	 begin
	   match lv with
	   | Asm.V (Asm.T r) ->
	      begin
		let key = Env.Key.Reg r in
		let top' =
		  try
		    let v = Env.find key m' in
		    let v' = D.forget v in
		    v'
		  with Not_found -> D.top
		in
	      Val (Env.add key top' m')
	      end
	   | _ -> forget m (*TODO: could be more precise *)
	 end
      | BOT -> BOT
		 
    let is_subset m1 m2 =
      match m1, m2 with
      | BOT, _ 		 -> true
      | _, BOT 		 -> false
      |	Val m1', Val m2' ->
         try Env.for_all2 D.is_subset m1' m2'
         with _ ->
           try
             Env.iteri (fun k v1 -> try let v2 = Env.find k m2' in if not (D.is_subset v1 v2) then raise Exit with Not_found -> ()) m1';
             true
           with Exit -> false
			  

    let coleasce_to_strs (m : D.t Env.t) (strs : string list) =
        let addr_zero = Data.Address.of_int Data.Address.Global Z.zero 0 in
        let prev_addr = ref addr_zero in
        let in_itv = ref false in
        let build_itv k _v itvs : ((Data.Address.t ref * Data.Address.t) list) =
            match k with
            | Env.Key.Reg _ -> in_itv := false; prev_addr := addr_zero; itvs
            | Env.Key.Mem_Itv (_low_addr, _high_addr) -> in_itv := false; prev_addr := addr_zero; itvs
            | Env.Key.Mem (addr) -> let new_itv =
                                    if !in_itv && Data.Address.compare (!prev_addr) (Data.Address.inc addr) == 0 then
                                        begin
                                            (* continue byte string *)
                                            prev_addr := addr;
                                            let cur_start = fst (List.hd itvs) in cur_start := addr;
                                            itvs
                                        end else begin
                                        (* not contiguous, create new itv *)
                                        in_itv := true;
                                        prev_addr := addr;
                                        let new_head = (ref addr, addr) in
                                        new_head :: itvs
                                    end
              in new_itv
        in
        let itv_to_str itv = let low = !(fst itv) in let high = snd itv in 
            let addr_str = Printf.sprintf "mem[%s, %s]" (Data.Address.to_string low) (Data.Address.to_string high) in
            let len = (Z.to_int (Data.Address.sub high low))+1 in
            let strs = let indices = Array.make len 0 in 
                for offset = 0 to len-1 do
                    indices.(offset) <- offset
                done ;
                let buffer = Buffer.create (len*10) in 
                Array.iter (fun off -> Printf.bprintf buffer ", %s" (D.to_string (Env.find (Env.Key.Mem (Data.Address.add_offset low (Z.of_int off))) m))) indices ;
                Buffer.contents buffer
            in Printf.sprintf "%s = %s" addr_str (String.sub strs 2 ((String.length strs)-2))
        in 
        let itvs = Env.fold build_itv m [] in 
        List.fold_left (fun strs v -> (itv_to_str v)::strs) strs itvs
    
    let non_itv_to_str k v =
        match k with
        | Env.Key.Reg _ | Env.Key.Mem_Itv(_,_) -> Printf.sprintf "%s = %s" (Env.Key.to_string k) (D.to_string v)
        | _ -> ""

    let to_string m =
      match m with
      |	BOT    -> ["_"]
      | Val m' -> let non_itv = Env.fold (fun k v strs -> let s = non_itv_to_str k v in if String.length s > 0 then s :: strs else strs) m' [] in
                  coleasce_to_strs m' non_itv
			   
    (***************************)
    (** Memory access function *)
    (***************************)
			   
    (* Helper to get an array of addresses : base..(base+nb-1) *)
    let get_addr_array base nb =
      let arr = Array.make nb base in
      for i = 0 to nb-1 do
        arr.(i) <- Data.Address.add_offset base (Z.of_int i);
      done;
      arr
	
    let get_addr_list base nb =
      Array.to_list (get_addr_array base nb)
		    
    (** compare the given _addr_ to key, for use in MapOpt.find_key.
    Remember that registers (key Env.Key.Reg) are before any address in the order defined in K *)
    let where addr key =
      match key with
      | Env.Key.Reg _ -> -1
      | Env.Key.Mem addr_k -> Data.Address.compare addr addr_k
      | Env.Key.Mem_Itv (a_low, a_high) ->
         if Data.Address.compare addr a_low < 0 then
           -1
         else
           if Data.Address.compare addr a_high > 0 then 1
           else 0 (* return 0 if a1 <= a <= a2 *)
	

    (** get byte from sections, depending on addr:
            - real value if in raw data
            - TOP if in section but not raw data
            - raise Not_found if not in sections *)
    let read_from_sections addr =
        let is_in_section addr section =
            if (Data.Address.compare addr section.virt_addr >= 0) &&
               (Data.Address.compare addr (Data.Address.add_offset section.virt_addr section.virt_size) < 0) then
                true else false in
        let sec = List.find (fun section_info -> is_in_section addr section_info) !sections_addr in
        (* check if we're out of the section's raw data *)
        let offset = (Data.Address.sub addr sec.virt_addr) in
            if Z.compare offset sec.raw_size > 0 then
                D.top
            else
                match !mapped_file with
                | None -> L.abort (fun p -> p "File not mapped!")
                | Some map -> D.of_word (Data.Word.of_int (Z.of_int (Bigarray.Genarray.get map [|(Z.to_int (Z.add sec.raw_addr offset))|])) 8)


    (** computes the value read from the map where _addr_ is located 
        The logic is the following:
            1) expand the base address and size to an array of addrs
            2) check "map" for existence
            3) if "map" contains the adresses, get the values and concat them
            4) else check in the "sections" maps and read from the file (or raise Not_found)
    **)
    let get_mem_value map addr sz =
      L.debug (fun p -> p "get_mem_value : %s %d" (Data.Address.to_string addr) sz);
      try
        (* expand the address + size to a list of addresses *)
        let exp_addrs = get_addr_list addr (sz/8) in

        (* find the corresponding keys in the map, will raise [Not_found] if no addr matches *)
        let vals = 
        try
            List.rev_map (fun cur_addr -> snd (Env.find_key (where cur_addr) map)) exp_addrs
        with Not_found ->
            L.debug (fun p -> p "\tNot found in mapping, checking sections");
            (* not in mem map, check file sections, again, will raise [Not_found] if not matched *)
            List.rev_map (fun cur_addr -> read_from_sections cur_addr) exp_addrs
        in

        (* TODO big endian, here the map is reversed so it should be ordered in little endian order *)
        let res = D.concat vals in
          L.debug (fun p -> p "get_mem_value result : %s" (D.to_string res));
        res
      with _ -> D.bot
		  
    (** helper to look for a an address in map, returns an option with None
            if no key matches *)
    let safe_find addr dom : (Env.key * 'a) option  =
      try
        let res = Env.find_key (where addr) dom in
        Some res
      with Not_found ->
        None
	  
    (** helper to split an interval at _addr_, returns a map with nothing
            at _addr_ but _itv_ split in 2 *)
    let split_itv domain itv addr =
      let map_val = Env.find itv domain in
      match itv with
      | Env.Key.Mem_Itv (low_addr, high_addr) ->
        L.debug (fun p -> p "Splitting (%s, %s) at %s" (Data.Address.to_string low_addr) (Data.Address.to_string high_addr) (Data.Address.to_string addr));
         let dom' = Env.remove itv domain in
         (* addr just below the new byte *)
         let addr_before = Data.Address.dec addr  in
         (* addr just after the new byte *)
         let addr_after = Data.Address.inc addr in
         (* add the new interval just before, if it's not empty *)
         let dom' =
           if Data.Address.equal addr low_addr || Data.Address.equal low_addr addr_before then begin
             dom'
           end else begin
             Env.add (Env.Key.Mem_Itv (low_addr, addr_before)) map_val dom'
           end
         in
         (* add the new interval just after, if its not empty *)
         let res = if Data.Address.equal addr high_addr || Data.Address.equal addr_after high_addr then begin
           dom'
         end else begin
             Env.add (Env.Key.Mem_Itv (addr_after, high_addr)) map_val dom'
         end
         in
         res
      | _ -> L.abort (fun p -> p "Trying to split a non itv")
		       
    (* strong update of memory with _byte_ repeated _nb_ times *)
    let write_repeat_byte_in_mem addr domain byte nb =
      let addrs = get_addr_list addr nb in
      (* helper to remove keys to be overwritten, splitting Mem_Itv
               as necessary *)
      let delete_mem  addr domain =
        let key = safe_find addr domain in
        match key with
        | None -> domain;
        | Some (Env.Key.Reg _,_) ->  L.abort (fun p -> p "Implementation error: the found key is a Reg")
        (* We have a byte, delete it *)
        | Some (Env.Key.Mem (_) as addr_k, _) -> Env.remove addr_k domain
        | Some (Env.Key.Mem_Itv (_, _) as key, _) ->
           split_itv domain key addr
      in
      let rec do_cleanup addrs map =
        match addrs with
        | [] -> map
        | to_del::l -> do_cleanup l (delete_mem to_del map) in
      let dom_clean = do_cleanup addrs domain in
      Env.add (Env.Key.Mem_Itv (addr, (Data.Address.add_offset addr (Z.of_int nb)))) byte dom_clean
	      
	      
    (* Write _value_ of size _sz_ in _domain_ at _addr_, in
           _big_endian_ if needed. _strong_ means strong update *)
    let write_in_memory addr domain value sz strong big_endian =
      L.debug (fun p -> p "write_in_mem (%s, %s, %d)" (Data.Address.to_string addr) (D.to_string value) sz);
      let nb = sz / 8 in
      let addrs = get_addr_list addr nb in
      let addrs = if big_endian then List.rev addrs else addrs in
      (* helper to update one byte in memory *)
      let update_one_key (addr, byte) domain =
          L.debug (fun p -> p "update_one_key (%s, %s)" (Data.Address.to_string addr) (D.to_string byte));
        let key = safe_find addr domain in
        match key with
        | Some (Env.Key.Reg _, _) -> L.abort (fun p -> p "Implementation error: the found key is a Reg")
        (* single byte to update *)
        | Some (Env.Key.Mem (_) as addr_k, match_val) ->
           if strong then
             Env.replace addr_k byte domain
           else
             Env.replace addr_k (D.join byte match_val) domain
        (* we have to split the interval *)
        | Some (Env.Key.Mem_Itv (_, _) as key, match_val) ->
           let dom' = split_itv domain key addr in
           if strong then
             Env.add (Env.Key.Mem(addr)) byte dom'
           else
             Env.add (Env.Key.Mem(addr)) (D.join byte match_val) dom'
        (* the addr was not previously seen *)
        | None -> if strong then
                    Env.add (Env.Key.Mem(addr)) byte domain
                  else
                    raise Exceptions.Empty
      in
      let rec do_update new_mem map =
        match new_mem with
        | [] -> map
        | new_val::l ->
	   do_update l (update_one_key new_val map)
      in
      let new_mem = List.mapi (fun i addr -> (addr, (D.extract value (i*8) ((i+1)*8-1)))) addrs in
      do_update new_mem domain
		
		
		
    (***************************)
    (* Non mem functions  :)   *)
    (***************************)
    (** opposite the given comparison operator *)
    let inv_cmp (cmp: Asm.cmp): Asm.cmp =
      (* TODO factorize with Interpreter *)
      match cmp with
      | Asm.EQ  -> Asm.NEQ
      | Asm.NEQ -> Asm.EQ
      | Asm.LT  -> Asm.GEQ
      | Asm.GEQ -> Asm.LT
      | Asm.LEQ -> Asm.GT
      | Asm.GT  -> Asm.LEQ


  
    (** evaluates the given expression
        returns the evaluated expression and a boolean to say if
        the resulting expression is tainted
    *)
    let rec eval_exp m e: (D.t * bool) =
      L.debug (fun p -> p "eval_exp(%s)" (Asm.string_of_exp e true));
      let rec eval e =
        match e with
        | Asm.Const c 			     -> D.of_word c, false
        | Asm.Lval (Asm.V (Asm.T r)) 	     ->
           begin
             try
	       let v = Env.find (Env.Key.Reg r) m in
	       v, D.is_tainted v
             with Not_found -> D.bot, false
           end
        | Asm.Lval (Asm.V (Asm.P (r, low, up))) ->
           begin
             try
               let v = Env.find (Env.Key.Reg r) m in
               let v' = D.extract v low up in
	       v', D.is_tainted v'
             with
             | Not_found -> D.bot, false
           end
        | Asm.Lval (Asm.M (e, n))            ->
           begin
             let r, b = eval e in
             try
               let addresses = Data.Address.Set.elements (D.to_addresses r) in
               let rec to_value a =
                 match a with
                 | [a]  -> let v = get_mem_value m a n in v, b || (D.is_tainted v)
                 | a::l ->
		    let v = get_mem_value m a n in
		    let v', b' = to_value l in
		    D.join v v', (D.is_tainted v)||b||b'
							
                 | []   -> raise Exceptions.Bot_deref
               in
               let value = to_value addresses
               in
               value
             with
             | Exceptions.Enum_failure               -> D.top, true
             | Not_found | Exceptions.Concretization ->
                            L.analysis (fun p -> p ("undefined memory dereference [%s]=[%s]: analysis stops in that context") (Asm.string_of_exp e true) (D.to_string r));
                            raise Exceptions.Bot_deref
           end
	     
        | Asm.BinOp (Asm.Xor, Asm.Lval (Asm.V (Asm.T r1)), Asm.Lval (Asm.V (Asm.T r2))) when Register.compare r1 r2 = 0 && Register.is_stack_pointer r1 ->
           let v = D.of_config Data.Address.Stack (Config.Content Z.zero) (Register.size r1) in
	   v, D.is_tainted v
		       
        | Asm.BinOp (Asm.Xor, Asm.Lval (Asm.V (Asm.T r1)), Asm.Lval (Asm.V (Asm.T r2))) when Register.compare r1 r2 = 0 ->
           D.untaint (D.of_word (Data.Word.of_int (Z.zero) (Register.size r1))), false

	     
        | Asm.BinOp (op, e1, e2) ->
	   let v1, b1 = eval e1 in
	   let v2, b2 = eval e2 in
	   let v = D.binary op v1 v2 in
	   v, b1 || b2 || (D.is_tainted v)
			    
        | Asm.UnOp (op, e) ->
	   let v, b = eval e in
	   let v' = D.unary op v in
	   v', b || (D.is_tainted v')

	| Asm.TernOp (c, e1, e2) ->
	   let r, b = eval_bexp c true in
       let res, taint_res = 
           if r then (* condition is true *)
             let r2, b2 = eval_bexp c false in
             if r2 then
               let v1, _ = eval e1 in
               let v2, _ = eval e2 in
               D.join v1 v2, b||b2
             else
               fst (eval e1), b
           else
             let r2, b2 = eval_bexp c false in
             if r2 then
               fst (eval e2), b2
             else
               D.bot, false
       in if taint_res then D.taint res, true else res, false
      (* TODO: factorize with Interpreter.restrict *)
      and eval_bexp c b: bool * bool =
        match c with
        | Asm.BConst b' 		  -> if b = b' then true, false else false, false
            | Asm.BUnOp (Asm.LogNot, e) 	  -> eval_bexp e (not b)

            | Asm.BBinOp (Asm.LogOr, e1, e2)  ->
               let v1, b1 = eval_bexp e1 b in
               let v2, b2 = eval_bexp e2 b in
               if b then v1||v2, b1||b2
               else v1&&v2, b1&&b2

            | Asm.BBinOp (Asm.LogAnd, e1, e2) ->
               let v1, b1 = eval_bexp e1 b in
               let v2, b2 = eval_bexp e2 b in
               if b then v1&&v2, b1&&b2
               else v1||v2, b1||b2

            | Asm.Cmp (cmp, e1, e2)   ->
               let cmp' = if b then cmp else inv_cmp cmp in
               compare_env m e1 cmp' e2
          in
          eval e
	
    and compare_env env (e1: Asm.exp) op e2 =
      let v1, b1 = eval_exp env e1 in
      let v2, b2 = eval_exp env e2 in
      D.compare v1 op v2, b1||b2


    let val_restrict m e1 _v1 cmp _e2 v2 =
      match e1, cmp with
      | Asm.Lval (Asm.V (Asm.T r)), cmp when cmp = Asm.EQ ->
         let v  = Env.find (Env.Key.Reg r) m in
         let v' = D.meet v v2        in
         if D.is_bot v' then
           raise Exceptions.Empty
         else
           Env.replace (Env.Key.Reg r) v' m
      | _, _ -> m
		  
    (* TODO factorize with compare_env *)
    let compare m (e1: Asm.exp) op e2 =
      match m with
      | BOT -> BOT, false
      | Val m' ->
	 let v1, b1 = eval_exp m' e1 in
         let v2, b2 = eval_exp m' e2 in
         if D.is_bot v1 || D.is_bot v2 then
           BOT, false
         else
           if D.compare v1 op v2 then
             try
               Val (val_restrict m' e1 v1 op e2 v2), b1||b2
             with Exceptions.Empty -> BOT, false
           else
             BOT, false
      	
    let mem_to_addresses m e =
      match m with
      | BOT -> raise Exceptions.Enum_failure
      | Val m' ->
         try let v, b = eval_exp m' e in D.to_addresses v, b
         with _ -> raise Exceptions.Enum_failure

    (** [span_taint m e v] span the taint of the strongest *tainted* value of e to all the fields of v.
    If e is untainted then nothing is done *)
    let span_taint m e (v: D.t) =
        L.debug (fun p -> p "span_taint(%s) v=%s"  (Asm.string_of_exp e true) (D.to_string v));
        let rec process e =
            match e with
            | Asm.Lval (Asm.V (Asm.T r)) ->
              let r' = Env.find (Env.Key.Reg r) m in
              D.get_minimal_taint r'
            | Asm.Lval (Asm.V (Asm.P (r, low, up))) ->
              let r' =  Env.find (Env.Key.Reg r) m in
              D.get_minimal_taint (D.extract r' low up)
            | Asm.Lval (Asm.M (e', _n)) -> process e'
            | Asm.BinOp (_, e1, e2) -> Tainting.min (process e1) (process e2)
            | Asm.UnOp (_, e') -> process e'
            | _ -> Tainting.U
        in
        match e with
        | Asm.BinOp (_, _e1, Asm.Lval (Asm.M (e2_m, _))) ->
          begin
              let taint = process e2_m in
              match taint with
              | Tainting.U -> v
              | _ -> D.span_taint v taint
          end
        | Asm.Lval (Asm.M (e', _)) ->
          begin
              let taint = process e' in
              match taint with
              | Tainting.U -> v
              | _ -> D.span_taint v taint
          end
        | Asm.UnOp(_, e') ->
          begin
              let taint = process e' in
              match taint with
              | Tainting.U -> v
              | _ -> D.span_taint v taint
          end
        | _ -> v
				
				
    let set dst src m: (t * bool) =
        match m with
        | BOT    -> BOT, false
        | Val m' ->
          let v', _ = eval_exp m' src in
          let v' = span_taint m' src v' in
          L.debug (fun p -> p "(set) %s = %s (%s)" (Asm.string_of_lval dst true) (Asm.string_of_exp src true) (D.to_string v'));
          let b = D.is_tainted v' in
          if D.is_bot v' then
              BOT, b
          else
              match dst with
              | Asm.V r -> 
                begin
                    match r with
                    | Asm.T r' ->
                      Val (Env.add (Env.Key.Reg r') v' m'), b
                    | Asm.P (r', low, up) ->
                      try
                          let prev = Env.find (Env.Key.Reg r') m' in		    
                          Val (Env.replace (Env.Key.Reg r') (D.combine prev v' low up) m'), b
                      with
                        Not_found -> BOT, b
                end
              | Asm.M (e, n) ->
                let v, b' = eval_exp m' e in
                let addrs = D.to_addresses v in
                let l     = Data.Address.Set.elements addrs in
                try
                    match l with
                    | [a] -> (* strong update *) Val (write_in_memory a m' v' n true false), b||b'
                    | l   -> (* weak update *) Val (List.fold_left (fun m a ->  write_in_memory a m v' n false false) m' l), b||b'
                with Exceptions.Empty -> BOT, false
                         
    let join m1 m2 =
      match m1, m2 with
      | BOT, m | m, BOT  -> m
      | Val m1', Val m2' ->
         try Val (Env.map2 D.join m1' m2')
         with _ ->
           let m = Env.empty in
           let m' = Env.fold (fun k v m -> Env.add k v m) m1' m in
           Val (Env.fold (fun k v m -> try let v' = Env.find k m1' in Env.replace k (D.join v v') m with Not_found -> Env.add k v m) m2' m')
	       
	       

    let meet m1 m2 =
      match m1, m2 with
      | BOT, _ | _, BOT  -> BOT
      | Val m1', Val m2' ->
	 if Env.is_empty m1' then
	   m2
	 else
	   if Env.is_empty m2' then
	   m1
	   else
	     let m' = Env.empty in
	     let m' = Env.fold (fun k v1 m' ->
	       try let v2 = Env.find k m2' in Env.add k (D.meet v1 v2) m' with Not_found -> m') m1' m' in
	     Val m'
				
    let widen m1 m2 =
      match m1, m2 with
      | BOT, m | m, BOT  -> m
      | Val m1', Val m2' ->
         try Val (Env.map2 D.widen m1' m2')
         with _ ->
           let m = Env.empty in
           let m' = Env.fold (fun k v m -> Env.add k v m) m1' m in
           Val (Env.fold (fun k v m -> try let v' = Env.find k m1' in let v2 = try D.widen v' v with _ -> D.top in Env.replace k v2 m with Not_found -> Env.add k v m) m2' m')
	       
	       
    let convert_section sec =
        match sec with (lvirt_addr, lvirt_size, lraw_addr, lraw_size, lname) ->
            { virt_addr = Data.Address.of_int Data.Address.Global lvirt_addr !Config.address_sz;
              virt_size = lvirt_size;
              raw_addr = lraw_addr;
              raw_size = lraw_size;
              name = lname }
    let init () = sections_addr := List.map convert_section !Config.sections ;
                  let bin_fd = Unix.openfile !Config.binary [Unix.O_RDONLY] 0 in
                  mapped_file := Some (Bigarray.Genarray.map_file bin_fd ~pos:Int64.zero Bigarray.int8_unsigned Bigarray.c_layout false [|-1|]);
		  Unix.close bin_fd;
                  Val (Env.empty)
		      
    (** returns size of content, rounded to the next multiple of Config.operand_sz *)
    let size_of_content c =
      let round_sz sz =
        if sz < !Config.operand_sz then
          !Config.operand_sz
        else
          if sz mod !Config.operand_sz <> 0 then
            !Config.operand_sz * (sz / !Config.operand_sz + 1)
          else
            sz
      in
      match c with
      | Config.Content z | Config.CMask (z, _) -> round_sz (Z.numbits z)
      | Config.Bytes b | Config.Bytes_Mask (b, _) -> (String.length b)*4
															    

    (** builds an abstract tainted value from a config concrete tainted value *)
    let of_config region (content, taint) sz =
      let v' = D.of_config region content sz in
      match taint with
      | Some taint' -> D.taint_of_config taint' sz v'
      | None 	-> D.taint_of_config (Config.Taint Z.zero) sz v'

    let taint_register_mask reg taint m =
      match m with
      | BOT -> BOT
      | Val m' ->
	 let k = Env.Key.Reg reg in
	 let v = Env.find k m' in
	 Val (Env.replace k (D.taint_of_config taint (Register.size reg) v) m')

    let taint_address_mask a taint m =
      match m with
      | BOT -> BOT
      | Val m' ->
	 let k = Env.Key.Mem a in
	 let v = Env.find k m' in
	 Val (Env.replace k (D.taint_of_config taint 8 v) m')

    let set_memory_from_config addr region (content, taint) nb domain =
      if nb > 0 then
        match domain with
        | BOT    -> BOT
        | Val domain' ->
           let sz = size_of_content content in
           let val_taint = of_config region (content, taint) sz in
           if nb > 1 then
             if sz != 8 then
               L.abort (fun p -> p "Repeated memory init only works with bytes")
             else
               Val (write_repeat_byte_in_mem addr domain' val_taint nb)
           else
             let big_endian =
               match content with
               | Config.Bytes _ | Config.Bytes_Mask (_, _) -> true
               | _ -> false
             in
             Val (write_in_memory addr domain' val_taint sz true big_endian)
      else
        domain
	  
    let set_register_from_config r region c m =
      match m with
      | BOT    -> BOT
      | Val m' ->
         let sz = Register.size r in
         let vt = of_config region c sz in
         Val (Env.add (Env.Key.Reg r) vt m')
	       
    let value_of_exp m e =
      match m with
      | BOT -> raise Exceptions.Concretization
      | Val m' -> D.to_z (fst (eval_exp m' e))


    let is_tainted e m =
        match m with
        | BOT -> false
        | Val m' -> snd (eval_exp m' e)


    let i_get_bytes (addr: Asm.exp) (cmp: Asm.cmp) (terminator: Asm.exp) (upper_bound: int) (sz: int) (m: t) (with_exception: bool) pad_options: (int * D.t list) =
      match m with
      | BOT -> raise Not_found
      | Val m' ->
	 let v, _ = eval_exp m' addr in
	 let addrs = Data.Address.Set.elements (D.to_addresses v) in
	 let term = fst (eval_exp m' terminator) in
	 let off = sz / 8 in
	 let rec find (a: Data.Address.t) (o: int): (int * D.t list) =
	   if o >= upper_bound then
	     if with_exception then raise Not_found
	       else o, [] 
	   else
	     let a' = Data.Address.add_offset a (Z.of_int o) in
	     let v = get_mem_value m' a' sz in
	     if D.compare v cmp term then
	       match pad_options with
	       | None -> o, []
	       | Some (pad_char, pad_left) ->
		  if o = upper_bound then upper_bound, []
		  else
		    let n = upper_bound-o in
		    let z = D.of_word (Data.Word.of_int (Z.of_int (Char.code pad_char)) 8) in
		    if pad_left then L.abort (fun p -> p "left padding in i_get_bytes not managed")
		    else
		      let chars = ref [] in
		      for _i = 0 to n-1 do
			chars := z::!chars
		      done;
		      upper_bound, !chars
	     else
	       let o', l = find a (o+off) in
	       o', v::l
	 in
	 match addrs with
	 | [a] -> find a 0 
	 | _::_ ->
	    let res = List.fold_left (fun acc a ->
	      try
		let n = find a 0 in
		match acc with
		| None -> Some n
		| Some prev -> Some (max prev n)
	      with _ -> acc) None addrs
	    in
	    begin
	      match res with
	      | Some n -> n
	      | None -> raise Not_found
	    end
	 | [] -> raise Not_found

    let get_bytes e cmp terminator (upper_bound: int) (sz: int) (m: t): int * Bytes.t =
      try
	let len, vals = i_get_bytes e cmp terminator upper_bound sz m true None in
	let bytes = Bytes.create len in
	(* TODO: endianess ! *)
	List.iteri (fun i v ->
	  Bytes.set bytes i (D.to_char v)) vals;
	len, bytes
      with _ -> raise Exceptions.Concretization
	
    let get_offset_from e cmp terminator upper_bound sz m = fst (i_get_bytes e cmp terminator upper_bound sz m true None)


   

   

    let copy_register r dst src =
      let k = Env.Key.Reg r in
      match dst, src with
      | Val dst', Val src' -> let v = Env.find k src' in Val (Env.replace k v dst')
      | BOT, Val src' -> let v = Env.find k src' in Val (let m = Env.empty in Env.add k v m)
      | _, _ -> BOT
	    

    let strip str = String.sub str 3 (String.length str - 3)
      
    let copy_until m dst e terminator term_sz upper_bound with_exception pad_options: int * t =
      match m with
      | Val m' ->
	 begin
	   let addrs = Data.Address.Set.elements (D.to_addresses (fst (eval_exp m' dst))) in
	   (* TODO optimize: m is pattern matched twice (here and in i_get_bytes) *)
	   let len, bytes = i_get_bytes e Asm.EQ terminator upper_bound term_sz m with_exception pad_options in
	   let copy_byte a m' strong =
	     let m', _ =
	       List.fold_left (fun (m', i) byte ->
		 let a' = Data.Address.add_offset a (Z.of_int i) in
	       (write_in_memory a' m' byte 8 strong false), i+1) (m', 0) bytes
	     in
	     m'
	   in						     
	   let m' =
	     match addrs with
	     | [a] -> copy_byte a m' true
	     | _::_  -> List.fold_left (fun m' a -> copy_byte a m' false) m' addrs
	     | [] -> raise Exceptions.Concretization
	   in
	   len, Val m'
	 end
      | BOT -> 0, BOT

    (* print nb bytes on stdout as raw string *)
    let print_bytes bytes nb =
          let str = Bytes.make nb ' ' in
              List.iteri (fun i c -> Bytes.set str i (D.to_char c)) bytes;
              Log.print (Bytes.to_string str);;

    let print_until m e terminator term_sz upper_bound with_exception pad_options =
      let len, bytes = i_get_bytes e Asm.EQ terminator upper_bound term_sz m with_exception pad_options in
      print_bytes bytes len;
      len, m
	
    let copy_chars m dst src nb pad_options =
      snd (copy_until m dst src (Asm.Const (Data.Word.of_int Z.zero 8)) 8 nb false pad_options)

    let print_chars m src nb pad_options =
        match m with
        | Val _ ->
          (* TODO: factorize with copy_until *)
          let bytes = snd (i_get_bytes src Asm.EQ (Asm.Const (Data.Word.of_int Z.zero 8)) nb 8 m false pad_options) in
          print_bytes bytes nb;
          m
        | BOT -> Log.print "_"; BOT

    let copy_chars_to_register m reg offset src nb pad_options =
      match m with
      |	Val m' ->
	 let terminator = Asm.Const (Data.Word.of_int Z.zero 8) in
	 let len, bytes = i_get_bytes src Asm.EQ terminator nb 8 m false pad_options in
	 begin
	   let new_v = D.concat bytes in
	   let key = Env.Key.Reg reg in
	   let new_v' =
	     if offset = 0 then new_v
	     else
	       try let prev = Env.find key m' in
		   let low = offset*8 in
		   D.combine prev new_v low (low*len-1)
	       with Not_found -> raise Exceptions.Empty
	   in
	   try Val (Env.replace key new_v' m')
	   with Not_found -> Val (Env.add key new_v m')
	 end
      | BOT -> BOT


    let to_hex m src nb capitalise pad_option full_print _word_sz: string * int =
        let capitalise str =
            if capitalise then String.uppercase str
            else str
        in
        let vsrc = fst (eval_exp m src) in
        let str_src, str_taint = D.to_strings vsrc in
        let str_src' = capitalise (strip str_src) in
        let sz = String.length str_src' in
        let str' =
            match pad_option with
            | Some (pad, pad_left) ->
              (*word_sz / 8 in*)
              let nb_pad = nb - sz in
              (* pad with the pad parameter if needed *)
              if nb_pad <= 0 then
                  if full_print then
                      if String.compare str_taint "0x0" = 0 then
                          str_src'	    
                      else
                          Printf.sprintf "%s!%s" str_src' str_taint
                  else
                      str_src'
              else
                  let pad_str = String.make nb_pad pad in
                  if pad_left then
                      let pad_src = pad_str ^ str_src' in
                      if full_print then
                          if String.compare str_taint "0x0" = 0 then
                              pad_src
                          else
                              Printf.sprintf "%s!%s" pad_src (pad_str^str_taint)
                      else
                          pad_src
                  else
                      let pad_src = str_src' ^ pad_str in
                      if full_print then
                          if String.compare str_taint "0x0" = 0 then
                              pad_src
                          else
                              Printf.sprintf "%s!%s" pad_src (str_taint^pad_str)
                      else
                          pad_src
            | None ->
              if full_print then
                  if String.compare str_taint "0x0" = 0 then
                      str_src'	    
                  else
                      Printf.sprintf "%s!%s" str_src' str_taint
              else
                  str_src'
        in
        str', String.length str'
	    
    let copy_hex m dst src nb capitalise pad_option word_sz: t * int =
        (* TODO generalise to non concrete src value *)
        match m with
        | Val m' ->
          begin
              let _, src_tainted = (eval_exp m' src) in
              let str_src, len = to_hex m' src nb capitalise pad_option false word_sz in
              let vdst = fst (eval_exp m' dst) in
              let dst_addrs = Data.Address.Set.elements (D.to_addresses vdst) in
              match dst_addrs with
              | [dst_addr] ->
                let znb = Z.of_int nb in
                let rec write m' o =
                    if Z.compare o znb < 0 then
                        let c = String.get str_src (Z.to_int o) in
                        let dst = Data.Address.add_offset dst_addr o in
                        let i' = Z.of_int (Char.code c) in
                        let r = D.of_word (Data.Word.of_int i' 8) in
                        let v' = if src_tainted || D.is_tainted r then D.taint r else r in
                        write (write_in_memory dst m' v' 8 true false) (Z.add o Z.one)
                    else
                        m'
                in
                Val (write m' Z.zero), len
              | [] -> raise Exceptions.Empty
              | _  -> Val (Env.empty), len (* TODO could be more precise *)
          end
        | BOT -> BOT, raise Exceptions.Empty

    let print_hex m src nb capitalise pad_option word_sz: t * int =
        match m with
        | Val m' -> 
          let str, len = to_hex m' src nb capitalise pad_option false word_sz in
          (* str is already stripped in hex *)
          Log.print str;
          m, len
        | BOT -> Log.print "_"; m, raise Exceptions.Empty

    let copy m dst arg sz: t =
	(* TODO: factorize pattern matching of dst with Interpreter.sprintf and with Unrel.copy_hex *)
	(* plus make pattern matching more generic for register detection *)
	match m with
	| Val m' ->
	   begin
	     let v = fst (eval_exp m' arg) in
	     let addrs = fst (eval_exp m' dst) in
	     match Data.Address.Set.elements (D.to_addresses addrs) with
	     | [a] ->
		Val (write_in_memory a m' v sz true false)
	     | _::_ as l -> Val (List.fold_left (fun m a -> write_in_memory a m v sz false false) m' l)
	     | [ ] -> raise Exceptions.Concretization
	   end
	| BOT -> BOT

    (* display (char) arg on stdout as a raw string *)
    let print m arg _sz: t =
        match m with
        | Val m' ->	
          let str = strip (D.to_string (fst (eval_exp m' arg))) in
          let str' =
              if String.length str <= 2 then
                  String.make 1 (Char.chr (Z.to_int (Z.of_string_base 16 str)))
              else raise Exceptions.Concretization
          in
          Log.print str';
          m
        | BOT -> Log.print "_"; m
  end
    
    
