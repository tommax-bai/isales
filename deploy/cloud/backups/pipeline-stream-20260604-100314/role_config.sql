--
-- PostgreSQL database dump
--

\restrict RBfIsceonFflk4ZSFqNolj1hHLX4bTznf0dQYGsbmmpuRHglOsziIcrMpxsf4Ia

-- Dumped from database version 13.23
-- Dumped by pg_dump version 13.23

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: role_config; Type: TABLE DATA; Schema: public; Owner: isales
--

COPY public.role_config (id, campaign_id, kind, model, current_prompt_version_id, temperature, top_p, ext_params, enabled, created_at, updated_at) FROM stdin;
1	1	role	qwen3.6-plus	1	0.7	1	{"name": "", "provider": "dashscope"}	t	2026-05-23 14:37:39.304822+08	2026-05-23 15:12:50.946153+08
3	1	judge	qwen3.6-flash	3	0.7	1	{"name": "", "provider": "dashscope"}	t	2026-05-23 15:04:34.894607+08	2026-05-23 15:12:53.929606+08
2	1	polish	qwen3.6-plus	2	0.7	1	{"name": "", "provider": "dashscope"}	t	2026-05-23 15:04:00.315047+08	2026-05-23 15:12:57.00156+08
\.


--
-- Name: role_config_id_seq; Type: SEQUENCE SET; Schema: public; Owner: isales
--

SELECT pg_catalog.setval('public.role_config_id_seq', 3, true);


--
-- PostgreSQL database dump complete
--

\unrestrict RBfIsceonFflk4ZSFqNolj1hHLX4bTznf0dQYGsbmmpuRHglOsziIcrMpxsf4Ia

