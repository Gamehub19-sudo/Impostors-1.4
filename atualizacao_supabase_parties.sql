-- Execute APÓS o SQL anterior, no mesmo projeto.
ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS max_players integer NOT NULL DEFAULT 12;
ALTER TABLE public.ii_rooms ADD COLUMN IF NOT EXISTS impostor_count integer NOT NULL DEFAULT 1;
ALTER TABLE public.ii_rooms DROP CONSTRAINT IF EXISTS ii_rooms_limits;
ALTER TABLE public.ii_rooms ADD CONSTRAINT ii_rooms_limits CHECK (max_players BETWEEN 2 AND 12 AND impostor_count BETWEEN 1 AND max_players-1);

CREATE OR REPLACE FUNCTION public.ii_create_room(p_name text,p_max_players integer,p_impostor_count integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE c text; i integer; made boolean:=false;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Ative Anonymous Sign-ins em Authentication'; END IF;
 IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 20 THEN RAISE EXCEPTION 'Nome deve ter 2 a 20 caracteres'; END IF;
 IF p_max_players NOT BETWEEN 2 AND 12 OR p_impostor_count NOT BETWEEN 1 AND p_max_players-1 THEN
  RAISE EXCEPTION 'Escolha 2 a 12 jogadores e menos impostores que jogadores'; END IF;
 FOR i IN 1..25 LOOP
  c:=upper(substr(encode(gen_random_bytes(5),'hex'),1,6));
  INSERT INTO public.ii_rooms(code,host_id,max_players,impostor_count)
  VALUES(c,auth.uid(),p_max_players,p_impostor_count) ON CONFLICT DO NOTHING;
  IF FOUND THEN made:=true; EXIT; END IF;
 END LOOP;
 IF NOT made THEN RAISE EXCEPTION 'Não foi possível gerar o código'; END IF;
 INSERT INTO public.ii_players(room_code,user_id,name) VALUES(c,auth.uid(),trim(p_name));
 RETURN jsonb_build_object('code',c);
END $$;

CREATE OR REPLACE FUNCTION public.ii_join_room(p_code text,p_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.ii_rooms%rowtype;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Não autenticado'; END IF;
 IF length(trim(coalesce(p_name,''))) NOT BETWEEN 2 AND 20 THEN RAISE EXCEPTION 'Nome inválido'; END IF;
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Party não encontrada'; END IF;
 IF r.status<>'waiting' THEN RAISE EXCEPTION 'Partida já começou'; END IF;
 IF (SELECT count(*) FROM public.ii_players WHERE room_code=r.code)>=r.max_players
 AND NOT EXISTS(SELECT 1 FROM public.ii_players WHERE room_code=r.code AND user_id=auth.uid())
 THEN RAISE EXCEPTION 'Sala cheia'; END IF;
 INSERT INTO public.ii_players(room_code,user_id,name) VALUES(r.code,auth.uid(),trim(p_name))
 ON CONFLICT(room_code,user_id) DO UPDATE SET name=excluded.name;
 RETURN jsonb_build_object('code',r.code);
END $$;

CREATE OR REPLACE FUNCTION public.ii_list_rooms()
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public AS $$
 SELECT coalesce(jsonb_agg(x),'[]'::jsonb) FROM (
  SELECT r.code,r.max_players,r.impostor_count,
   (SELECT count(*) FROM public.ii_players p WHERE p.room_code=r.code) AS count
  FROM public.ii_rooms r WHERE r.status='waiting'
   AND r.created_at>now()-interval '24 hours'
  ORDER BY r.created_at DESC LIMIT 30
 ) x;
$$;

CREATE OR REPLACE FUNCTION public.ii_start_room(p_code text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.ii_rooms%rowtype; n integer;
BEGIN
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code)) FOR UPDATE;
 IF NOT FOUND OR r.host_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Somente o anfitrião pode começar'; END IF;
 IF r.status<>'waiting' THEN RAISE EXCEPTION 'Partida já começou'; END IF;
 SELECT count(*) INTO n FROM public.ii_players WHERE room_code=r.code;
 IF n < r.impostor_count+1 THEN
  RAISE EXCEPTION 'São necessários pelo menos % jogadores para % impostor(es)',r.impostor_count+1,r.impostor_count;
 END IF;
 UPDATE public.ii_players SET role='innocent',alive=true,tasks=0 WHERE room_code=r.code;
 UPDATE public.ii_players SET role='impostor' WHERE room_code=r.code AND user_id IN (
  SELECT user_id FROM public.ii_players WHERE room_code=r.code ORDER BY random() LIMIT r.impostor_count
 );
 UPDATE public.ii_rooms SET status='playing',meeting_until=NULL WHERE code=r.code;
END $$;

CREATE OR REPLACE FUNCTION public.ii_room_state(p_code text,p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE r public.ii_rooms%rowtype; me public.ii_players%rowtype; people jsonb; ev jsonb; latest bigint;
BEGIN
 SELECT * INTO r FROM public.ii_rooms WHERE code=upper(trim(p_code));
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Party não encontrada'); END IF;
 SELECT * INTO me FROM public.ii_players WHERE room_code=r.code AND user_id=auth.uid();
 IF NOT FOUND THEN RETURN jsonb_build_object('error','Você não está nesta party'); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.user_id,'name',p.name,'alive',p.alive,'tasks',p.tasks,'is_host',p.user_id=r.host_id) ORDER BY p.joined_at),'[]'::jsonb)
 INTO people FROM public.ii_players p WHERE p.room_code=r.code;
 SELECT coalesce(max(id),0) INTO latest FROM public.ii_events WHERE room_code=r.code;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',e.id,'kind',e.kind,'target_id',e.target_id,
 'killer_name',CASE WHEN e.target_id=auth.uid() THEN e.killer_name ELSE NULL END) ORDER BY e.id),'[]'::jsonb)
 INTO ev FROM (SELECT * FROM public.ii_events WHERE room_code=r.code AND id>greatest(p_after,0) ORDER BY id LIMIT 100) e;
 RETURN jsonb_build_object('code',r.code,'status',r.status,'is_host',r.host_id=auth.uid(),
 'max_players',r.max_players,'impostor_count',r.impostor_count,
 'players',people,'role',CASE WHEN r.status='playing' THEN me.role ELSE NULL END,
 'alive',me.alive,'tasks',me.tasks,'meeting_until',r.meeting_until,'events',ev,'latest_id',latest);
END $$;

REVOKE ALL ON FUNCTION public.ii_create_room(text,integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.ii_create_room(text,integer,integer) TO authenticated;
-- Remove a versão antiga para evitar criação de salas sem opções.
DROP FUNCTION IF EXISTS public.ii_create_room(text);
