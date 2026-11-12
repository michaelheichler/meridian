# Beyond and Behind the Screen

Source. Designing Interfaces, Patterns for Effective Interaction Design, 3rd Edition (Jenifer Tidwell, Charles Brewer, Aynne Valencia, 2020), Chapter 12, "Beyond and Behind the Screen" (the book's closing chapter).

## In one line

As interfaces move from user-driven screen interactions toward invisible, automated systems driven by sensors and algorithms, the goal remains to reduce user effort and increase clarity, even without a screen.

## Core ideas

- Social media, publishing, and ecommerce often share an interaction structure. Someone contributes content or a transaction, a system stores and mediates it, and users view, act on, or reuse the result. These recurring interactions let one pattern catalog cover different domains.
- As backend systems gain rules engines and machine learning that infers patterns and classifications, algorithms take on more complexity. That added capability should simplify what the user sees and does. Work the system handles should become work the user no longer has to do.
- Ubiquitous computing, including IoT and the "industrial internet", embeds connected sensors in ordinary objects and spaces. They sense the environment and report back, often without drawing attention. Designers must account for interactions that have no screen and that users may not consciously notice.
- Active input through typing, clicking, or forms increasingly gives way to ambient signals from behavior, location, and sensors, plus lightweight confirmation. Users move from entering data to confirming or overriding what the system inferred or did. Off-screen inference should make their interaction simpler.
- The book's foundations still apply. Sound UI architecture, Gestalt-based visual hierarchy, and accessible help reduce cognitive load and make state and options understandable, including when the interface has no traditional screen.
- Designers must imagine scenarios and define the rules an autonomous system follows in ambiguous situations. Designers use those scenarios to decide how the system should act in edge cases before it acts without supervision.
- The chapter closes with a responsibility for designers of automated, ambient, and AI-driven systems to make the result human-centered and beneficial rather than merely functional.

## Named patterns and principles

This chapter introduces system categories rather than step-by-step patterns such as Center Stage or Wizard. Use these categories to scope non-screen design problems, not as UI components to implement directly.

### Connected Devices

Any object with internet connectivity belongs here, including phones, TVs, cars, thermostats, light bulbs, and pet feeders. Use this category when a product extends past a single app or website into physical objects with sensors. Connectivity supplies the basis for sensing, inference, and ambient interaction.

### Anticipatory Systems

These systems observe behavior and suggest or take action without a separate request each time. A connected fridge that reorders milk when supply runs low is one example. Use anticipation when reliable signals reveal a recurring need and advance action or suggestion saves effort. Removing repetitive tasks helps only when inference earns trust and the cost of an error stays low or users can reverse it. Otherwise, anticipation can feel intrusive or unreliable.

### Assistive Systems

Assistive technology extends human capabilities without replacing the user's decisions. Use it when the goal is to extend physical, cognitive, or sensory ability rather than substitute the system's judgment for the user's. This relationship keeps the user in control and supports trust as automation increases.

### Natural User Interfaces (NUI)

NUI uses motion, gesture, touch, voice, or other sensory input rather than keyboard-and-pointer conventions. The chapter gives touchscreens, Amazon Alexa for voice, and Microsoft Kinect for gesture as examples. Choose these inputs when a physical or spoken action, such as tapping, squeezing, waving, or speaking, fits better than a conventional GUI control. Matching familiar physical behavior can reduce the learning effort and make interaction part of ordinary activity.

## How to apply

- Identify the recurring interaction structure before designing a product. Content contribution, viewing, and moderation often reuse social or publishing patterns, while catalogs and transactions reuse ecommerce patterns.
- When a backend gains algorithmic or ML capability, look for a step to remove from the user's workflow instead of adding a smarter result to the same workflow. More backend intelligence should mean less user work.
- Design the no-screen case for connected devices and sensor-driven features. Decide what users see, hear, or feel when the system acts, and how they correct an error.
- Give automated behavior an explicit way to confirm, approve, or override an action. Match that interaction to the consequences and reversibility of the action. More consequential or difficult-to-reverse actions need clearer confirmation.
- Keep clear hierarchy, Gestalt grouping, and accessible help in ambient and voice interfaces. Translate those principles into the available modality through audio hierarchy, spoken confirmations, or haptic cues rather than dropping them when no screen exists.
- Before shipping autonomous behavior, write the scenarios and rules for edge cases. Treat scenario-writing as a design deliverable rather than an engineering afterthought.
- Evaluate the effects of automated, data-driven decisions on users and society as a design requirement before launch.

## Watch out for

- Do not use added system intelligence as a reason to hide decisions without a way to inspect, confirm, or reverse them. An invisible interface should reduce effort without reducing control.
- NUI and ambient interfaces still need clarity and hierarchy. A different modality does not remove the user's need to understand what is happening.
- Automatic actions such as orders or data sharing create greater trust risks than suggestions. Match confirmation and reversibility to the cost of an error.
