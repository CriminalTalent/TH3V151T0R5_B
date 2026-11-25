# 레이드 웹 페이지

`WEB_ENABLED=true` 일 때만 전투봇 안에서 작은 웹서버가 뜹니다(기본 `127.0.0.1:4567`).
꺼두면 기존 전투에는 아무 영향이 없습니다. 시트 API를 추가로 호출하지 않고, 봇 메모리 상태만 보여줍니다.

| 주소 | 내용 |
|---|---|
| `/` , `/spectator` | 관전자 페이지 (격자맵, HP, 라운드 타이머, 전투 기록) |
| `/api/battles` | 관전 데이터 JSON |

## .env
```
WEB_ENABLED=true
WEB_PORT=4567
# DM/비공개 전투도 관전 페이지에 보이게 하려면
# WEB_SHOW_DM=true
```

## nginx (기존 server 블록 안에 추가)
```
location /raid/ {
    proxy_pass http://127.0.0.1:4567/;
}
```
접속: `https://<도메인>/raid/`
