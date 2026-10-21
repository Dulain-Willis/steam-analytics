{# unknown_member: the sentinel dim_users.user_id value an orphan
   client_events.user_id resolves to (steam-infra #140 dropped the FK; #141
   is the handling half). One literal, shared by dim_users (which unions in
   the sentinel row) and fct_product_funnel_sessions (which coalesces an
   unresolved user_id to it), so the two always agree without either
   hardcoding the other's string. #}
{% macro unknown_member() -%} unknown_member {%- endmacro %}
