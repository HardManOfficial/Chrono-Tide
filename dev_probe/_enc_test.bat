@echo off
set "CT_E2E_GAME=E:\GAL\°×É«Ïà²¾2\WA2_chs.exe"
echo GAME=[%CT_E2E_GAME%]
if exist "%CT_E2E_GAME%" (echo RESULT=EXISTS) else (echo RESULT=MISSING)
