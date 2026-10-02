<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
	<UiMod name="CPlusHomeRecord" version="0.2" date="10/02/2026">

		<Author name="BrauneRatte" />
		<Description text="Writes out what is in the locked down containers of your own houses when you close them" />

		<Dependencies>
			<Dependency name="ClfCommon" />
			<!--
				ClfContainerMod wraps ContainerWindow.Initialize in its own
				initialize. Depending on it makes this module initialize after
				it, so the wrapper installed here goes round that one.
			-->
			<Dependency name="ClfContainerMod" />
		</Dependencies>

		<Files>
			<File name="CPlusHomeTexts.lua" />
			<File name="CPlusHomeRecord.lua" />
			<File name="CPlusHomeSupport.lua" />
			<File name="CPlusHomeGuide.lua" />
			<File name="CPlusHomeArea.lua" />
		</Files>

		<OnInitialize>
			<CallFunction name="CPlusHomeRecord.initialize" />
		</OnInitialize>

		<OnShutdown>
			<CallFunction name="CPlusHomeGuide.shutdown" />
			<CallFunction name="CPlusHomeArea.shutdown" />
			<CallFunction name="CPlusHomeRecord.shutdown" />
		</OnShutdown>

	</UiMod>
</ModuleFile>
